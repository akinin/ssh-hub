#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
build_dir="${1:-build}"
mkdir -p "$build_dir"
build_dir="${build_dir:A}"
go_bin="${SSH_HUB_GO:-$(command -v go || true)}"
[[ -n "$go_bin" ]] || { echo 'Нужен Go 1.24+ для сборки WireGuard (пользователю приложения Go не нужен).' >&2; exit 1; }
cd WireGuardHelper
mkdir -p "$build_dir/wg-arm64" "$build_dir/wg-x86_64"
CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 "$go_bin" build -mod=vendor -trimpath -ldflags='-s -w' -o "$build_dir/wg-arm64/SSHWG" .
CGO_ENABLED=0 GOOS=darwin GOARCH=amd64 "$go_bin" build -mod=vendor -trimpath -ldflags='-s -w' -o "$build_dir/wg-x86_64/SSHWG" .
lipo -create "$build_dir/wg-arm64/SSHWG" "$build_dir/wg-x86_64/SSHWG" -output "$build_dir/SSHWG"
SSH_HUB_WG_HELPER="$build_dir/SSHWG" "$go_bin" test -mod=vendor -count=1 ./...
python3 - "$build_dir/WireGuard-LICENSES.txt" "$("$go_bin" env GOROOT)/LICENSE" <<'PY'
from pathlib import Path
import sys
texts=['Go runtime\n'+Path(sys.argv[2]).read_text()]
for p in sorted(Path('vendor').rglob('*')):
 if p.is_file() and p.name.upper() in ('LICENSE','LICENSE.TXT','COPYING','COPYRIGHT','NOTICE'):
  texts.append(str(p)+'\n'+p.read_text(errors='replace'))
Path(sys.argv[1]).write_text('\n\n'.join(texts))
PY
