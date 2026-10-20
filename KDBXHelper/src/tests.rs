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
        let request=Request{id:"test".into(),op:"open".into(),path:Some(path.to_str().unwrap().into()),master_password:Some("synthetic master".into()),key_path:None,entry_id:None};
        let(vault,catalog)=open(&request).unwrap();
        assert!(!catalog.to_string().contains("synthetic-fixture-secret"));
        let id:uuid::Uuid=catalog["entries"][0]["id"].as_str().unwrap().parse().unwrap();
        assert_eq!(secret(&vault,id).unwrap()["password"],"synthetic-fixture-secret");
        let mut wrong=Request{id:"wrong".into(),op:"open".into(),path:request.path.clone(),master_password:Some("wrong".into()),key_path:None,entry_id:None};
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
            let req=Request{id:"fixture".into(),op:"open".into(),path:Some(dir.join("db.kdbx").to_str().unwrap().into()),master_password:Some("synthetic master".into()),key_path:keyfile.as_ref().map(|_|dir.join("key").to_str().unwrap().into()),entry_id:None};
            let (vault,catalog)=open(&req).unwrap();assert_eq!(catalog["entries"].as_array().unwrap().len(),3);assert!(!catalog.to_string().contains("Never catalog trash"));assert_eq!(secret(&vault,normal).unwrap()["username"],"fixture");
            assert_eq!(secret(&vault,expired_id).unwrap_err(),"entry_expired");assert_eq!(secret(&vault,reference).unwrap_err(),"unsupported_reference");assert_eq!(secret(&vault,uuid::Uuid::new_v4()).unwrap_err(),"entry_missing");
            for index in [bytes.len()-1,bytes.len()/2] {let mut broken=bytes.clone();broken[index]^=1;std::fs::write(dir.join("db.kdbx"),broken).unwrap();assert!(open(&req).is_err());}
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
