#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
build_dir="${1:-build}"
output_dir="${2:-dist}"
mkdir -p "$build_dir" "$output_dir"
build_dir="${build_dir:A}"
output_dir="${output_dir:A}"
if [[ "${3:-}" != "--skip-build" ]]; then
    zsh Scripts/build.sh "$build_dir"
fi
zsh ./Scripts/sign-app.sh --verify "$build_dir/SSH Hub.app"
python3 Tests/UniversalBuildTests.py "$build_dir/SSH Hub.app"
stage_dir="$(mktemp -d /private/tmp/ssh-aliases-dmg.XXXXXX)"
trap 'rm -rf "$stage_dir"' EXIT
ditto --norsrc --noextattr "$build_dir/SSH Hub.app" "$stage_dir/SSH Hub.app"
ln -s /Applications "$stage_dir/Applications"
xattr -cr "$stage_dir/SSH Hub.app"
codesign --verify --deep --strict "$stage_dir/SSH Hub.app"
hdiutil create -volname "SSH Hub" -srcfolder "$stage_dir" -fs HFS+ -ov -format UDZO "$output_dir/SSH-Hub-macOS.dmg"
identity="${SSH_HUB_SIGN_IDENTITY:-$(<Signing/signing-identity.sha1)}"
if [[ "$identity" != '-' ]]; then
    zsh Scripts/sign-app.sh --check > /dev/null
    codesign --force --sign "$identity" --timestamp --identifier com.olshaniki.ssh-hub.dmg "$output_dir/SSH-Hub-macOS.dmg"
    codesign --verify --strict "$output_dir/SSH-Hub-macOS.dmg"
fi
hdiutil verify "$output_dir/SSH-Hub-macOS.dmg"
echo "Готово: $output_dir/SSH-Hub-macOS.dmg"
