#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
build_dir="${1:-build}"
output_dir="${2:-dist}"
mkdir -p "$build_dir" "$output_dir"
build_dir="${build_dir:A}"
output_dir="${output_dir:A}"
if [[ "${3:-}" != "--skip-build" ]]; then
    zsh build.sh "$build_dir"
fi
zsh ./sign-app.sh --verify "$build_dir/SSH Hub.app"
stage_dir="$(mktemp -d /private/tmp/ssh-aliases-dmg.XXXXXX)"
trap 'rm -rf "$stage_dir"' EXIT
ditto --norsrc --noextattr "$build_dir/SSH Hub.app" "$stage_dir/SSH Hub.app"
ln -s /Applications "$stage_dir/Applications"
xattr -cr "$stage_dir/SSH Hub.app"
codesign --verify --deep --strict "$stage_dir/SSH Hub.app"
hdiutil create -volname "SSH Hub" -srcfolder "$stage_dir" -fs HFS+ -ov -format UDZO "$output_dir/SSH-Hub-macOS.dmg"
hdiutil verify "$output_dir/SSH-Hub-macOS.dmg"
echo "Готово: $output_dir/SSH-Hub-macOS.dmg"
