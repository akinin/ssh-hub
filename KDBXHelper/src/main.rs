//! SSH Hub read-only KDBX worker. Secrets use inherited private pipes only.
use keepass::{Database, DatabaseKey, db::{EntryId, GroupRef, Times}};
use serde::Deserialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{collections::HashSet, fs::OpenOptions, io::{self, BufRead, Read, Write}, os::unix::fs::OpenOptionsExt};
use zeroize::Zeroize;

const MAX_FILE: u64 = 64 * 1024 * 1024;
const MAX_FRAME: usize = 32768;
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    id: String,
    op: String,
    path: Option<String>,
    master_password: Option<String>,
    key_path: Option<String>,
    entry_id: Option<uuid::Uuid>,
}
impl Drop for Request { fn drop(&mut self) { if let Some(p) = &mut self.master_password { p.zeroize(); } } }
struct Vault { database: Database, path: String, hash: Vec<u8>, allowed: HashSet<uuid::Uuid>, expired: HashSet<uuid::Uuid> }
fn file_bytes(path: &str, maximum: u64) -> Result<Vec<u8>, &'static str> {
    if path.len() > 4096 || !path.starts_with('/') || path.contains('\0') { return Err("invalid_path"); }
    let mut file = OpenOptions::new().read(true).custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK).open(path).map_err(|_| "file_unavailable")?;
    let before = file.metadata().map_err(|_| "file_unavailable")?;
    if !before.is_file() || before.len() > maximum { return Err("file_limit"); }
    let mut data = Vec::new();
    (&mut file).take(maximum + 1).read_to_end(&mut data).map_err(|_| "file_unavailable")?;
    let after = file.metadata().map_err(|_| "file_unavailable")?;
    if data.len() as u64 > maximum || before.len() != after.len() || before.modified().ok() != after.modified().ok() { return Err("file_changed"); }
    Ok(data)
}
fn safe(text: &str, maximum: usize) -> bool { text.len() <= maximum && !text.chars().any(|c| c.is_control()) }
fn expired(times: &Times) -> bool { times.expires == Some(true) && times.expiry <= Times::now() }
fn catalog_group(group: GroupRef<'_>, path: String, trash: Option<uuid::Uuid>, inherited_expired: bool, depth: usize, rows: &mut Vec<Value>, allowed: &mut HashSet<uuid::Uuid>) -> Result<(), &'static str> {
    if trash == Some(group.id().uuid()) { return Ok(()); }
    if depth > 64 || rows.len() > 2000 { return Err("catalog_limit"); }
    let group_expired = inherited_expired || expired(&group.times);
    for entry in group.entries() {
        if rows.len() >= 2000 { return Err("catalog_limit"); }
        let title = entry.get_title().unwrap_or("KeePass entry");
        let user = entry.get_username().unwrap_or("");
        if !safe(title, 512) || !safe(user, 512) { continue; }
        let id = entry.id().uuid();
        if !allowed.insert(id) { return Err("invalid_database"); }
        rows.push(json!({"id":id,"title":title,"username":user,"group":path,"expired":group_expired || expired(&entry.times),"modified":entry.times.last_modification.map(|d|d.and_utc().timestamp())}));
    }
    for child in group.groups() {
        let name: String = child.name.chars().filter(|c| !c.is_control()).take(80).collect();
        let child_path = if path.is_empty() { name } else { format!("{path}/{name}") };
        if child_path.len() > 2048 { return Err("catalog_limit"); }
        catalog_group(child, child_path, trash, group_expired, depth + 1, rows, allowed)?;
    }
    Ok(())
}
fn open(request: &Request) -> Result<(Vault, Value), &'static str> {
    let path = request.path.as_ref().ok_or("invalid_request")?;
    let data = file_bytes(path, MAX_FILE)?;
    // This connector deliberately accepts only KDBX, not KDB or plugin key sources.
    if data.len() < 12 || data[..8] != [0x03,0xd9,0xa2,0x9a,0x67,0xfb,0x4b,0xb5] || ![3u16,4].contains(&u16::from_le_bytes([data[10],data[11]])) { return Err("unsupported_format"); }
    let mut key = DatabaseKey::new();
    if let Some(password) = &request.master_password { if password.len() > 16384 || password.contains('\0') { return Err("invalid_request"); }; key = key.with_password(password); }
    if let Some(key_path) = &request.key_path {
        let mut bytes = file_bytes(key_path, 1024 * 1024)?;
        let parsed = key.with_keyfile(&mut io::Cursor::new(&bytes));
        bytes.zeroize(); key = parsed.map_err(|_| "invalid_keyfile")?;
    }
    let database = Database::parse(&data, key).map_err(|_| "credentials_or_corrupt")?;
    let mut rows = Vec::new(); let mut allowed = HashSet::new();
    catalog_group(database.root(), String::new(), database.meta.recyclebin_uuid, false, 0, &mut rows, &mut allowed)?;
    rows.sort_by_key(|row| format!("{}/{}", row["group"],row["title"]));
    let expired = rows.iter().filter(|r| r["expired"] == true).filter_map(|r| r["id"].as_str().and_then(|id| id.parse().ok())).collect();
    let result = json!({"entries":rows});
    if serde_json::to_vec(&result).map_err(|_| "catalog_limit")?.len() > 1_500_000 { return Err("catalog_limit"); }
    Ok((Vault { database, path: path.clone(), hash: Sha256::digest(&data).to_vec(), allowed, expired }, result))
}
fn secret(vault: &Vault, id: uuid::Uuid) -> Result<Value, &'static str> {
    if !vault.allowed.contains(&id) { return Err("entry_missing"); }
    let current = file_bytes(&vault.path, MAX_FILE)?;
    if Sha256::digest(&current).as_slice() != vault.hash { return Err("file_changed"); }
    let entry = vault.database.entry(EntryId::from_uuid(id)).ok_or("entry_missing")?;
    if expired(&entry.times) { return Err("entry_expired"); }
    if vault.expired.contains(&id) { return Err("entry_expired"); }
    let username = entry.get_username().unwrap_or(""); let password = entry.get_password().ok_or("password_missing")?;
    if !safe(username, 512) || !safe(password, 16384) { return Err("invalid_credential"); }
    if [username, password].iter().any(|v| v.contains("{REF:") || v.contains("{S:")) { return Err("unsupported_reference"); }
    Ok(json!({"username":username,"password":password}))
}
fn response(id: &str, result: Result<Value, &'static str>) -> Value { match result { Ok(value) => json!({"id":id,"ok":true,"result":value}), Err(code) => json!({"id":id,"ok":false,"code":code}) } }
fn run(reader: &mut impl BufRead, writer: &mut impl Write) -> io::Result<()> {
    let mut vault: Option<Vault> = None;
    loop {
        let mut line = Vec::new();
        let count = (&mut *reader).take((MAX_FRAME + 1) as u64).read_until(b'\n', &mut line)?;
        if count == 0 { return Ok(()); }
        if count > MAX_FRAME || !line.ends_with(b"\n") { line.zeroize(); return Ok(()); }
        let parsed = serde_json::from_slice::<Request>(&line); line.zeroize();
        let request = match parsed { Ok(r) if safe(&r.id, 64) && !r.id.is_empty() => r, _ => return Ok(()) };
        let result = match request.op.as_str() {
            "open" if vault.is_none() => match open(&request) { Ok((value, catalog)) => { vault = Some(value); Ok(catalog) }, Err(code) => Err(code) },
            "read" => match (vault.as_ref(), request.entry_id) { (Some(v),Some(id)) => secret(v,id), _ => Err("locked") },
            "close" => return Ok(()),
            _ => Err("invalid_request"),
        };
        let fatal = matches!(result, Err("file_changed"));
        let mut bytes = serde_json::to_vec(&response(&request.id, result)).map_err(io::Error::other)?;
        bytes.push(b'\n'); let output = writer.write_all(&bytes).and_then(|_| writer.flush()); bytes.zeroize(); output?;
        if fatal { return Ok(()); }
    }
}
fn main() {
    // No core dumps, inherited environment secrets or diagnostic payloads.
    unsafe { let limit = libc::rlimit { rlim_cur:0, rlim_max:0 }; libc::setrlimit(libc::RLIMIT_CORE, &limit); }
    std::panic::set_hook(Box::new(|_| {}));
    let input=io::stdin(); let output=io::stdout();
    let _ = run(&mut input.lock(), &mut output.lock());
}

#[cfg(test)] mod tests;
