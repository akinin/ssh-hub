use super::*;
use keepass::preserving::{Document, Item, Node};
use std::{
    fs::{self, File},
    os::unix::fs::MetadataExt,
    path::{Path, PathBuf},
};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Edit {
    pub title: String,
    pub username: String,
    pub password: String,
    pub url: String,
    pub notes: String,
    pub group_id: uuid::Uuid,
}
impl Drop for Edit {
    fn drop(&mut self) {
        self.password.zeroize();
        self.notes.zeroize();
    }
}
fn uid(n: &Node) -> Option<uuid::Uuid> {
    // UUIDs are base64 in KeePass XML. Use the typed database's UUID representation via hex-free decoding.
    use keepass::preserving::uuid_from_text;
    n.child("UUID").and_then(|n| uuid_from_text(&n.text()))
}
fn field(n: &Node, key: &str) -> String {
    n.children()
        .find(|n| n.name == "String" && n.child("Key").map(Node::text).as_deref() == Some(key))
        .and_then(|n| n.child("Value"))
        .map(Node::text)
        .unwrap_or_default()
}
fn find<'a>(n: &'a Node, name: &str, id: uuid::Uuid) -> Option<&'a Node> {
    if n.name == name && uid(n) == Some(id) {
        return Some(n);
    }
    n.children()
        .filter(|n| n.name != "History")
        .find_map(|n| find(n, name, id))
}
fn find_mut<'a>(n: &'a mut Node, name: &str, id: uuid::Uuid) -> Option<&'a mut Node> {
    if n.name == name && uid(n) == Some(id) {
        return Some(n);
    }
    n.children_mut()
        .filter(|n| n.name != "History")
        .find_map(|n| find_mut(n, name, id))
}
pub fn groups(root: &Node) -> Vec<Value> {
    fn visit(n: &Node, path: String, trash: &str, out: &mut Vec<Value>) {
        if n.name == "Group" {
            if n.child("UUID").map(Node::text).as_deref() == Some(trash) {
                return;
            }
            let name: String = n
                .child("Name")
                .map(Node::text)
                .unwrap_or_default()
                .chars()
                .filter(|c| !c.is_control())
                .take(80)
                .collect();
            let path = if path.is_empty() {
                name
            } else {
                format!("{path}/{name}")
            };
            if path.len() > 2048 || out.len() >= 2000 {
                return;
            }
            if let Some(id) = uid(n) {
                out.push(json!({"id":id,"title":if path.is_empty(){"Корень базы"}else{&path}}));
            }
            for c in n.children().filter(|n| n.name == "Group") {
                visit(c, path.clone(), trash, out);
            }
        } else {
            for c in n
                .children()
                .filter(|n| n.name == "Root" || n.name == "Group")
            {
                visit(c, path.clone(), trash, out);
            }
        }
    }
    let trash = root
        .child("Meta")
        .and_then(|n| n.child("RecycleBinUUID"))
        .map(Node::text)
        .unwrap_or_default();
    let mut result = vec![];
    visit(root, String::new(), &trash, &mut result);
    result
}
fn checked(v: &Vault) -> Result<(), &'static str> {
    let bytes = file_bytes(&v.path, MAX_FILE)?;
    if Sha256::digest(bytes).as_slice() != v.hash {
        return Err("file_changed");
    }
    Ok(())
}
pub fn detail(v: &Vault, id: uuid::Uuid) -> Result<Value, &'static str> {
    checked(v)?;
    if !v.allowed.contains(&id) {
        return Err("entry_missing");
    }
    let (doc, _) = v.editor.as_ref().ok_or("read_only_format")?;
    let entry = find(&doc.root, "Entry", id).ok_or("entry_missing")?;
    let group = parent(&doc.root, id).ok_or("entry_missing")?;
    let versions=entry.child("History").map(|h|h.children().filter(|n|n.name=="Entry").map(|n| json!({"title":field(n,"Title"),"modified":n.child("Times").and_then(|n|n.child("LastModificationTime")).map(Node::text)})).collect::<Vec<_>>()).unwrap_or_default();
    Ok(
        json!({"title":field(entry,"Title"),"username":field(entry,"UserName"),"password":field(entry,"Password"),"url":field(entry,"URL"),"notes":field(entry,"Notes"),"group_id":group,"history_count":versions.len()}),
    )
}
fn parent(n: &Node, id: uuid::Uuid) -> Option<uuid::Uuid> {
    if n.name == "Group"
        && n.children()
            .any(|c| c.name == "Entry" && uid(c) == Some(id))
    {
        return uid(n);
    }
    n.children()
        .filter(|n| n.name != "History")
        .find_map(|n| parent(n, id))
}
fn take(n: &mut Node, id: uuid::Uuid) -> Option<Node> {
    if let Some(i) = n
        .items
        .iter()
        .position(|i| matches!(i,Item::Node(c) if c.name=="Entry" && uid(c)==Some(id)))
    {
        if let Item::Node(c) = n.items.remove(i) {
            return Some(c);
        }
    }
    n.children_mut()
        .filter(|n| n.name != "History")
        .find_map(|n| take(n, id))
}
fn set_field(n: &mut Node, key: &str, text: &str, policy: bool) -> Result<(), &'static str> {
    let position=n.items.iter().position(|x| matches!(x,Item::Node(c) if c.name=="String" && c.child("Key").map(Node::text).as_deref()==Some(key)));
    let node = if let Some(i) = position {
        match &mut n.items[i] {
            Item::Node(n) => n,
            _ => unreachable!(),
        }
    } else {
        let mut field = Node::new("String");
        field.ensure("Key").set_text(key, false);
        let offset = n
            .items
            .iter()
            .rposition(|i| matches!(i,Item::Node(c) if c.name=="String"))
            .map(|i| i + 1)
            .unwrap_or_else(|| {
                n.items
                    .iter()
                    .position(|i| matches!(i,Item::Node(c) if c.name=="Binary"||c.name=="History"))
                    .unwrap_or(n.items.len())
            });
        n.items.insert(offset, Item::Node(field));
        match &mut n.items[offset] {
            Item::Node(n) => n,
            _ => unreachable!(),
        }
    };
    if node
        .child("Value")
        .is_some_and(|n| n.children().next().is_some())
    {
        return Err("unsupported_xml");
    }
    let protected = policy
        || key == "Password"
        || node
            .child("Value")
            .is_some_and(|n| n.attrs.iter().any(|(k, v)| k == "Protected" && v == "True"));
    node.ensure("Value").set_text(text, protected);
    Ok(())
}
struct OwnedPath(PathBuf);
impl Drop for OwnedPath {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}
fn create(path: &Path, bytes: &[u8]) -> Result<File, &'static str> {
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)
        .map_err(|_| "write_failed")?;
    file.write_all(bytes)
        .and_then(|_| file.sync_all())
        .map_err(|_| "write_failed")?;
    Ok(file)
}
pub fn save(v: &mut Vault, id: Option<uuid::Uuid>, edit: &Edit) -> Result<Value, &'static str> {
    if !safe(&edit.title, 512)
        || edit.title.trim().is_empty()
        || !safe(&edit.username, 512)
        || !safe(&edit.password, 16384)
        || !safe(&edit.url, 4096)
        || edit.notes.len() > 8192
        || edit
            .notes
            .chars()
            .any(|c| c.is_control() && !['\n', '\r', '\t'].contains(&c))
    {
        return Err("invalid_edit");
    }
    checked(v)?;
    let (doc, key) = v.editor.as_ref().ok_or("read_only_format")?;
    if !groups(&doc.root)
        .iter()
        .any(|g| g["id"] == edit.group_id.to_string())
    {
        return Err("invalid_group");
    }
    let path = Path::new(&v.path);
    let directory = path.parent().ok_or("write_failed")?;
    let meta = fs::symlink_metadata(path).map_err(|_| "file_unavailable")?;
    if meta.file_type().is_symlink()
        || !meta.is_file()
        || meta.nlink() != 1
        || meta.uid() != unsafe { libc::getuid() }
        || meta.mode() & 0o200 == 0
    {
        return Err("write_unavailable");
    }
    let source = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
        .map_err(|_| "file_unavailable")?;
    if unsafe {
        libc::flock(
            std::os::fd::AsRawFd::as_raw_fd(&source),
            libc::LOCK_EX | libc::LOCK_NB,
        )
    } != 0
    {
        return Err("database_busy");
    }
    if fs::symlink_metadata(format!("{}.lock", v.path)).is_ok() {
        return Err("database_busy");
    }
    // A stable hidden anchor coordinates our writers across atomic inode replacement.
    // The OS releases flock on termination; the empty anchor is retained, never stale-deleted.
    let lockpath = directory.join(format!(
        ".{}.ssh-hub.lock",
        path.file_name().ok_or("write_failed")?.to_string_lossy()
    ));
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(&lockpath)
        .map_err(|_| "database_busy")?;
    let info = lock.metadata().map_err(|_| "write_unavailable")?;
    if !info.is_file()
        || info.uid() != unsafe { libc::getuid() }
        || info.nlink() != 1
        || info.mode() & 0o077 != 0
        || info.len() != 0
    {
        return Err("write_unavailable");
    }
    if unsafe {
        libc::flock(
            std::os::fd::AsRawFd::as_raw_fd(&lock),
            libc::LOCK_EX | libc::LOCK_NB,
        )
    } != 0
    {
        return Err("database_busy");
    }
    checked(v)?;
    let original = file_bytes(&v.path, MAX_FILE)?;
    let mut staged = Document::open(&original, key)?;
    let entry_id = id.unwrap_or_else(uuid::Uuid::new_v4);
    let old_parent = id.and_then(|id| parent(&staged.root, id));
    let mut entry = if let Some(id) = id {
        if !v.allowed.contains(&id) {
            return Err("entry_missing");
        }
        find(&staged.root, "Entry", id)
            .ok_or("entry_missing")?
            .clone()
    } else {
        let mut entry = Node::new("Entry");
        entry
            .ensure("UUID")
            .set_text(&keepass::preserving::uuid_text(entry_id), false);
        entry
    };
    let now = keepass::preserving::timestamp_now();
    if id.is_some() {
        let mut previous = entry.clone();
        previous
            .items
            .retain(|n| !matches!(n,Item::Node(c) if c.name=="History"));
        entry.ensure("History").items.push(Item::Node(previous));
    } else {
        entry
            .ensure("Times")
            .ensure("CreationTime")
            .set_text(&now, false);
        entry
            .ensure("Times")
            .ensure("Expires")
            .set_text("False", false);
    }
    for (name, value) in [
        ("Title", edit.title.as_str()),
        ("UserName", edit.username.as_str()),
        ("Password", edit.password.as_str()),
        ("URL", edit.url.as_str()),
        ("Notes", edit.notes.as_str()),
    ] {
        let policy = staged
            .root
            .child("Meta")
            .and_then(|n| n.child("MemoryProtection"))
            .and_then(|n| n.child(&format!("Protect{name}")))
            .map(Node::text)
            .as_deref()
            == Some("True");
        set_field(&mut entry, name, value, policy)?;
    }
    entry
        .ensure("Times")
        .ensure("LastModificationTime")
        .set_text(&now, false);
    if let Some(old) = old_parent.filter(|old| *old != edit.group_id) {
        if staged.supports_previous_parent() {
            entry
                .ensure("PreviousParentGroup")
                .set_text(&keepass::preserving::uuid_text(old), false);
        }
        entry
            .ensure("Times")
            .ensure("LocationChanged")
            .set_text(&now, false);
    }
    if old_parent == Some(edit.group_id) {
        *find_mut(&mut staged.root, "Entry", entry_id).ok_or("entry_missing")? = entry;
    } else {
        if id.is_some() {
            take(&mut staged.root, entry_id).ok_or("entry_missing")?;
        }
        let group = find_mut(&mut staged.root, "Group", edit.group_id).ok_or("invalid_group")?;
        let offset = group
            .items
            .iter()
            .rposition(|i| matches!(i,Item::Node(c) if c.name=="Entry"))
            .map(|i| i + 1)
            .unwrap_or_else(|| {
                group
                    .items
                    .iter()
                    .position(|i| matches!(i,Item::Node(c) if c.name=="Group"))
                    .unwrap_or(group.items.len())
            });
        group.items.insert(offset, Item::Node(entry));
    }
    staged.root.normalize();
    let encrypted = staged.save(key)?;
    let database = Database::parse(&encrypted, key.clone()).map_err(|_| "verification_failed")?;
    let mut rows = vec![];
    let mut allowed = HashSet::new();
    catalog_group(
        database.root(),
        String::new(),
        database.meta.recyclebin_uuid,
        false,
        0,
        &mut rows,
        &mut allowed,
    )?;
    if serde_json::to_vec(&json!({"entries":rows,"groups":groups(&staged.root)}))
        .map_err(|_| "catalog_limit")?
        .len()
        > 1_490_000
    {
        return Err("catalog_limit");
    }
    let backup = directory.join(format!(
        "{}.ssh-hub-{}.backup.kdbx",
        path.file_name().ok_or("write_failed")?.to_string_lossy(),
        uuid::Uuid::new_v4()
    ));
    let temp = directory.join(format!(".ssh-hub-{}.kdbx", uuid::Uuid::new_v4()));
    let _temp_guard = OwnedPath(temp.clone());
    create(&temp, &encrypted)?;
    checked(v)?;
    let current = fs::symlink_metadata(path).map_err(|_| "file_changed")?;
    if current.dev() != meta.dev() || current.ino() != meta.ino() || current.nlink() != 1 {
        return Err("file_changed");
    }
    create(&backup, &original)?;
    File::open(directory)
        .and_then(|f| f.sync_all())
        .map_err(|_| "write_failed")?;
    checked(v)?;
    fs::rename(&temp, path).map_err(|_| "write_failed")?;
    // The encrypted backup is deliberately retained even if directory sync or the response fails.
    let _ = File::open(directory).and_then(|f| f.sync_all());
    v.hash = Sha256::digest(&encrypted).to_vec();
    v.database = database;
    v.expired = rows
        .iter()
        .filter(|r| r["expired"] == true)
        .filter_map(|r| r["id"].as_str().and_then(|s| s.parse().ok()))
        .collect();
    v.allowed = allowed;
    v.editor = Some((staged, key.clone()));
    rows.sort_by_key(|r| format!("{}/{}", r["group"], r["title"]));
    Ok(
        json!({"entries":rows,"entry_id":entry_id,"writable":true,"groups":groups(&v.editor.as_ref().unwrap().0.root),"backup_name":backup.file_name().unwrap().to_string_lossy()}),
    )
}
