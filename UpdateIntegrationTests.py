"""Run the shipped installer helper against temporary app bundles; never launches UI."""
import hashlib,json,pathlib,shutil,subprocess,sys,tempfile,plistlib
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
    def run(source,destination=target):
        job.write_text(json.dumps(dict(source=source.as_uri(),destination=destination.as_uri(),version=version(new),parentPID=2147483647,status=status.as_uri(),launch=False)))
        subprocess.run([str(helper),str(job)],check=True,timeout=30)
        return json.loads(status.read_text())
    result=run(new)
    assert result['success'],result
    backup=pathlib.Path(result['backup'])
    assert binary(target)==binary(new) and binary(backup)==original
    assert version(target)==version(new) and version(backup)==version(old)
    # Tampered payload must fail signature verification before replacing anything.
    invalid=root/'Invalid.app';subprocess.run(['ditto','--norsrc','--noextattr',str(new),str(invalid)],check=True)
    executable=invalid/'Contents/MacOS/SSHHub';data=bytearray(executable.read_bytes());data[4096]^=1;executable.write_bytes(data)
    before=binary(target);result=run(invalid)
    assert not result['success'] and binary(target)==before,result
    link=root/'Linked.app';link.symlink_to(target,target_is_directory=True)
    result=run(new,link)
    assert not result['success'] and binary(target)==before,result
assert binary(old)==original,'Original app was modified'
print('Update installer integration passed: atomic replacement, preserved backup, signature rejection, symlink destination rejection and unchanged original app; UI not launched')
