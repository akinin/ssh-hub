"""Collect the original license texts of the exact locked runtime dependency graph."""
import json, pathlib, subprocess, sys
manifest = pathlib.Path(__file__).resolve().with_name('Cargo.toml')
metadata = json.loads(subprocess.check_output(['cargo', 'metadata', '--locked', '--format-version', '1', '--filter-platform', 'aarch64-apple-darwin', '--manifest-path', str(manifest)]))
packages = {p['id']: p for p in metadata['packages']}
nodes = {n['id']: n for n in metadata['resolve']['nodes']}
root = metadata['resolve']['root']; seen = set()
def visit(key):
    if key in seen: return
    seen.add(key)
    for dependency in nodes[key]['deps']:
        if any(k['kind'] != 'dev' for k in dependency['dep_kinds']): visit(dependency['pkg'])
visit(root)
texts = ['SSH Hub KeePass handler: third-party notices\n']
for package in sorted((packages[k] for k in seen if k != root), key=lambda p: (p['name'], p['version'])):
    folder = pathlib.Path(package['manifest_path']).parent
    licenses = [p for p in folder.iterdir() if p.is_file() and (p.name.lower().startswith(('license', 'copying', 'copyright')))]
    if not licenses:
        licenses = list(manifest.with_name('licenses').glob(package['name'] + '-' + package['version'] + '-LICENSE*'))
    if not licenses: raise SystemExit(f"Missing license text: {package['name']}")
    texts.append(f"\n{'=' * 72}\n{package['name']} {package['version']}\n{package.get('repository') or ''}\nLicense: {package.get('license') or 'see below'}\n")
    for path in sorted(licenses): texts.append(path.name + '\n' + path.read_text())
pathlib.Path(sys.argv[1]).write_text('\n'.join(texts))
