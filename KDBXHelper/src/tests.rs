use super::*;
use keepass::{config::{KdfConfig,OuterCipherConfig},db::fields};
fn fixture(cipher: OuterCipherConfig) -> Vec<u8> {
    let mut db=Database::new(); db.config.outer_cipher_config=cipher; db.config.kdf_config=KdfConfig::Aes { rounds:6000 };
    let mut root=db.root_mut(); let mut entry=root.add_entry();
    entry.set_unprotected(fields::TITLE,"Owned fixture"); entry.set_unprotected(fields::USERNAME,"fixture"); entry.set_protected(fields::PASSWORD,"synthetic-fixture-secret");
    let mut data=Vec::new(); db.save(&mut data,DatabaseKey::new().with_password("synthetic master")).unwrap();data
}
#[test] fn authenticated_read_only_aes_chacha() {
    for cipher in [OuterCipherConfig::AES256,OuterCipherConfig::ChaCha20] {
        let path=std::env::temp_dir().join(format!("ssh-hub-kdbx-{}.kdbx",uuid::Uuid::new_v4()));
        let original=fixture(cipher);std::fs::write(&path,&original).unwrap();
        let request=Request{id:"test".into(),op:"open".into(),path:Some(path.to_str().unwrap().into()),master_password:Some("synthetic master".into()),key_path:None,entry_id:None,draft:None};
        let(vault,catalog)=open(&request).unwrap();
        assert!(!catalog.to_string().contains("synthetic-fixture-secret"));
        let id:uuid::Uuid=catalog["entries"][0]["id"].as_str().unwrap().parse().unwrap();
        assert_eq!(secret(&vault,id).unwrap()["password"],"synthetic-fixture-secret");
        let mut wrong=Request{id:"wrong".into(),op:"open".into(),path:request.path.clone(),master_password:Some("wrong".into()),key_path:None,entry_id:None,draft:None};
        assert!(open(&wrong).is_err());
        assert_eq!(std::fs::read(&path).unwrap(),original);
        wrong.path=None;
        std::fs::write(&path,b"changed").unwrap(); assert_eq!(secret(&vault,id).unwrap_err(),"file_changed");
        std::fs::remove_file(path).unwrap();
    }
}
#[test] fn bounded_protocol_and_unknown_fields() {
    let secret="synthetic private request";
    let input=format!("{{\"id\":\"t\",\"op\":\"read\",\"master_password\":\"{secret}\"}}\n");let mut out=Vec::new();run(&mut io::Cursor::new(input),&mut out).unwrap();
    let text=String::from_utf8(out).unwrap();assert!(!text.contains(secret));assert!(text.contains("locked"));
    for input in [b"{\"id\":\"a\",\"op\":\"open\",\"unknown\":1}\n".to_vec(),vec![b'a';MAX_FRAME+2]] { let mut out=Vec::new();run(&mut io::Cursor::new(input),&mut out).unwrap();assert!(out.is_empty()); }
}
#[test] fn kdf_keyfiles_integrity_and_catalog() {
    let version=match Database::new().config.kdf_config { KdfConfig::Argon2{version,..} => version, _=>panic!() };
    let configs=[KdfConfig::Argon2{iterations:2,memory:1024*1024,parallelism:1,version},KdfConfig::Argon2id{iterations:2,memory:1024*1024,parallelism:1,version}];
    for kdf in configs {
        for keyfile in [None,Some(vec![42u8;32]),Some(b"<KeyFile><Meta><Version>1.00</Version></Meta><Key><Data>KioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKio=</Data></Key></KeyFile>".to_vec())] {
            let dir=std::env::temp_dir().join(format!("ssh-hub-kdbx-{}",uuid::Uuid::new_v4()));std::fs::create_dir(&dir).unwrap();
            let mut db=Database::new();db.config.kdf_config=kdf.clone();
            let (normal,expired_id,reference,trash_id)={ let mut root=db.root_mut();
                let mut e=root.add_entry();e.set_unprotected(fields::TITLE,"Owned fixture");e.set_unprotected(fields::USERNAME,"fixture");e.set_protected(fields::PASSWORD,"synthetic-fixture-secret");let normal=e.id().uuid();
                let mut e=root.add_entry();e.times.expires=Some(true);e.set_unprotected(fields::TITLE,"Expired");e.set_protected(fields::PASSWORD,"expired-secret");let expired=e.id().uuid();
                let mut e=root.add_entry();e.set_unprotected(fields::TITLE,"Reference");e.set_protected(fields::PASSWORD,"{REF:P@T:other}");let reference=e.id().uuid();
                let mut trash=root.add_group();let trash_id=trash.id().uuid();let mut e=trash.add_entry();e.set_unprotected(fields::TITLE,"Never catalog trash");
                (normal,expired,reference,trash_id) };
            db.meta.recyclebin_uuid=Some(trash_id);
            let mut key=DatabaseKey::new().with_password("synthetic master");
            if let Some(bytes)=&keyfile { key=key.with_keyfile(&mut io::Cursor::new(bytes)).unwrap(); std::fs::write(dir.join("key"),bytes).unwrap(); }
            let mut bytes=Vec::new();db.save(&mut bytes,key).unwrap();std::fs::write(dir.join("db.kdbx"),&bytes).unwrap();
            let req=Request{id:"fixture".into(),op:"open".into(),path:Some(dir.join("db.kdbx").to_str().unwrap().into()),master_password:Some("synthetic master".into()),key_path:keyfile.as_ref().map(|_|dir.join("key").to_str().unwrap().into()),entry_id:None,draft:None};
            let (mut vault,catalog)=open(&req).unwrap();assert_eq!(catalog["entries"].as_array().unwrap().len(),3);assert!(!catalog.to_string().contains("Never catalog trash"));assert_eq!(secret(&vault,normal).unwrap()["username"],"fixture");
            assert_eq!(secret(&vault,expired_id).unwrap_err(),"entry_expired");assert_eq!(secret(&vault,reference).unwrap_err(),"unsupported_reference");assert_eq!(secret(&vault,uuid::Uuid::new_v4()).unwrap_err(),"entry_missing");
            for index in [bytes.len()-1,bytes.len()/2] {let mut broken=bytes.clone();broken[index]^=1;std::fs::write(dir.join("db.kdbx"),broken).unwrap();assert!(open(&req).is_err());}
            std::fs::write(dir.join("db.kdbx"),&bytes).unwrap();
            let group=groups(&vault.editor.as_ref().unwrap().0.root)[0]["id"].as_str().unwrap().parse().unwrap();
            let draft=Edit{title:"KDF round trip".into(),username:"fixture".into(),password:"owned updated secret".into(),url:String::new(),notes:String::new(),group_id:group};
            save(&mut vault,Some(normal),&draft).unwrap();
            let (reopened,_)=open(&req).unwrap();assert_eq!(secret(&reopened,normal).unwrap()["password"],"owned updated secret");
            std::fs::remove_dir_all(dir).unwrap();
        }
    }
}
#[test] fn native_fixture() {
    if let Ok(root)=std::env::var("SSH_HUB_KDBX_FIXTURE") {
        let dir=std::path::PathBuf::from(root);assert!(dir.is_absolute());std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("native.kdbx"),fixture(OuterCipherConfig::AES256)).unwrap();
    }
}

#[test] fn writes_preserve_uuid_history_fields_attachments_and_encrypted_backup() {
    use keepass::{db::Value as DBValue, preserving::{Document,Node,Item}};
    for cipher in [OuterCipherConfig::AES256,OuterCipherConfig::ChaCha20,OuterCipherConfig::Twofish] {
        let dir=std::env::temp_dir().join(format!("ssh-hub-kdbx-write-{}",uuid::Uuid::new_v4()));std::fs::create_dir(&dir).unwrap();
        let path=dir.join("owned.kdbx");let key=DatabaseKey::new().with_password("synthetic master");
        let mut db=Database::new();db.config.outer_cipher_config=cipher;db.config.kdf_config=KdfConfig::Aes{rounds:1000};
        let group=db.root_mut().add_group().id();
        let mut root=db.root_mut(); let mut e=root.add_entry();
        e.set_unprotected(fields::TITLE,"Before & <title>");e.set_unprotected(fields::USERNAME,"fixture");e.set_protected(fields::PASSWORD,"original-secret");e.set_protected("otp","otpauth://synthetic");
        e.add_attachment("owned.bin",DBValue::protected(vec![0,1,2,255]));let id=e.id();
        let mut original=vec![];db.save(&mut original,key.clone()).unwrap();
        // Include plugin/XML data not represented by the typed library: it must survive unchanged.
        let mut doc=Document::open(&original,&key).unwrap();let mut extension=Node::new("SSHHubOwnedExtension");extension.attrs.push(("custom".into(),"a&b".into()));extension.set_text("unknown <data> & 😀",false);doc.root.items.push(Item::Node(extension));
        let original=doc.save(&key).unwrap();std::fs::write(&path,&original).unwrap();
        let request=Request{id:"open".into(),op:"open".into(),path:Some(path.to_str().unwrap().into()),master_password:Some("synthetic master".into()),key_path:None,entry_id:None,draft:None};
        let(mut vault,catalog)=open(&request).unwrap();assert_eq!(catalog["writable"],true);
        let draft=Edit{title:"After & <title> 😀".into(),username:"changed-user".into(),password:"changed-fixture-secret".into(),url:"https://example.invalid/p?a=1&b=2".into(),notes:"Line one\nLine two <x> & 😀".into(),group_id:group.uuid()};
        let result=save(&mut vault,Some(id.uuid()),&draft).unwrap();
        assert_eq!(result["entry_id"],id.uuid().to_string());assert!(!result.to_string().contains("changed-fixture-secret"));
        let backup=dir.join(result["backup_name"].as_str().unwrap());assert_eq!(std::fs::read(backup).unwrap(),original);
        let bytes=std::fs::read(&path).unwrap();assert!(!bytes.windows(22).any(|x|x==b"changed-fixture-secret"));
        let reopened=Database::parse(&bytes,key.clone()).unwrap();let e=reopened.entry(id).unwrap();
        assert_eq!(e.get_password(),Some("changed-fixture-secret"));assert_eq!(e.fields["otp"].get(),"otpauth://synthetic");
        assert_eq!(e.attachment_by_name("owned.bin").unwrap().data.get(),&vec![0,1,2,255]);
        assert_eq!(e.history.as_ref().unwrap().get_entries().len(),1);assert_eq!(e.history.as_ref().unwrap().get_entries()[0].get_password(),Some("original-secret"));
        assert_eq!(e.parent().id(),group);
        let checked=Document::open(&bytes,&key).unwrap();assert_eq!(checked.root.child("SSHHubOwnedExtension").unwrap().text(),"unknown <data> & 😀");
        let detail=detail(&vault,id.uuid()).unwrap();assert_eq!(detail["history_count"],1);assert_eq!(detail["notes"],draft.notes);
        let created=save(&mut vault,None,&draft).unwrap();assert_ne!(created["entry_id"],id.uuid().to_string());assert_eq!(vault.allowed.len(),2);
        assert!(!dir.join("owned.kdbx.lock").exists());
        std::fs::remove_dir_all(dir).unwrap();
    }
}

#[test] fn conflict_busy_symlink_and_permissions_never_overwrite() {
    use std::os::unix::fs::{symlink,PermissionsExt};
    let dir=std::env::temp_dir().join(format!("ssh-hub-kdbx-cas-{}",uuid::Uuid::new_v4()));std::fs::create_dir(&dir).unwrap();
    let path=dir.join("owned.kdbx");let original=fixture(OuterCipherConfig::AES256);std::fs::write(&path,&original).unwrap();
    let req=Request{id:"open".into(),op:"open".into(),path:Some(path.to_str().unwrap().into()),master_password:Some("synthetic master".into()),key_path:None,entry_id:None,draft:None};
    let(mut vault,catalog)=open(&req).unwrap();let id=catalog["entries"][0]["id"].as_str().unwrap().parse().unwrap();
    let group=groups(&vault.editor.as_ref().unwrap().0.root)[0]["id"].as_str().unwrap().parse().unwrap();
    let draft=Edit{title:"Changed".into(),username:"fixture".into(),password:"new-fixture".into(),url:String::new(),notes:String::new(),group_id:group};
    std::fs::write(dir.join("owned.kdbx.lock"),b"owned other app lock").unwrap();assert_eq!(save(&mut vault,Some(id),&draft).unwrap_err(),"database_busy");assert_eq!(std::fs::read(&path).unwrap(),original);assert!(dir.join("owned.kdbx.lock").exists());std::fs::remove_file(dir.join("owned.kdbx.lock")).unwrap();
    std::fs::set_permissions(&path,std::fs::Permissions::from_mode(0o400)).unwrap();assert_eq!(save(&mut vault,Some(id),&draft).unwrap_err(),"write_unavailable");std::fs::set_permissions(&path,std::fs::Permissions::from_mode(0o600)).unwrap();
    std::fs::write(&path,b"another application changed this file").unwrap();assert_eq!(save(&mut vault,Some(id),&draft).unwrap_err(),"file_changed");assert_eq!(std::fs::read(&path).unwrap(),b"another application changed this file");
    std::fs::remove_file(&path).unwrap();symlink(dir.join("target"),&path).unwrap();assert!(save(&mut vault,Some(id),&draft).is_err());assert!(!dir.join("target").exists());
    std::fs::remove_dir_all(dir).unwrap();
}
