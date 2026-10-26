"""Run the shipped installer helper against temporary app bundles; never launches UI."""
import hashlib,json,pathlib,shutil,subprocess,sys,tempfile,plistlib,uuid
helper,old,new=map(lambda value:pathlib.Path(value).resolve(),sys.argv[1:4])
def version(app):
    return plistlib.loads((app/'Contents/Info.plist').read_bytes())['CFBundleShortVersionString']
def binary(app):
    return hashlib.sha256((app/'Contents/MacOS/SSHHub').read_bytes()).hexdigest()
original=binary(old)
with tempfile.TemporaryDirectory(prefix='ssh-hub-update-test-',dir='/private/tmp') as name:
    root=pathlib.Path(name);target=root/'SSH Hub.app'
    subprocess.run(['ditto','--norsrc','--noextattr',str(old),str(target)],check=True)
    status=root/'result.json';job=root/'job.json'
    unrelated=root/('.SSH-Hub-backup-'+str(uuid.uuid4())+'.app');(unrelated/'Contents').mkdir(parents=True)
    (unrelated/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'org.example.unrelated','CFBundleShortVersionString':'1.0.0'}))
    linked_backup=root/('.SSH-Hub-backup-'+str(uuid.uuid4())+'.app');linked_backup.symlink_to(unrelated,target_is_directory=True)
    future=root/('.SSH-Hub-backup-'+str(uuid.uuid4())+'.app');(future/'Contents').mkdir(parents=True)
    (future/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'com.olshaniki.ssh-aliases','CFBundleShortVersionString':'999.0.0'}))
    def run(source,destination=target):
        job.write_text(json.dumps(dict(source=source.as_uri(),destination=destination.as_uri(),version=version(new),parentPID=2147483647,status=status.as_uri(),launch=False)))
        subprocess.run([str(helper),str(job)],check=True,timeout=30)
        return json.loads(status.read_text())
    result=run(new)
    assert result['success'],result
    assert result.get('backup') is None,result
    assert binary(target)==binary(new) and version(target)==version(new)
    assert unrelated.exists() and linked_backup.is_symlink(),'Cleanup touched unrelated bundle or symlink'
    assert set(root.glob('.SSH-Hub-backup-*.app'))=={unrelated,linked_backup,future},[p.name for p in root.glob('.SSH-Hub-backup-*.app')]
    # Tampered payload must fail signature verification before replacing anything.
    invalid=root/'Invalid.app';subprocess.run(['ditto','--norsrc','--noextattr',str(new),str(invalid)],check=True)
    executable=invalid/'Contents/MacOS/SSHHub';data=bytearray(executable.read_bytes());data[4096]^=1;executable.write_bytes(data)
    before=binary(target);result=run(invalid)
    assert not result['success'] and binary(target)==before,result
    link=root/'Linked.app';link.symlink_to(target,target_is_directory=True)
    result=run(new,link)
    assert not result['success'] and binary(target)==before,result
assert binary(old)==original,'Original app was modified'
print('Update installer integration passed: atomic replacement, temporary backup cleanup, signature rejection, symlink destination rejection and unchanged original app; UI not launched')
