#!/bin/zsh
# Authentication stays in the user's notarytool Keychain profile.
set -euo pipefail
cd "${0:A:h:h}"
[[ $# == 2 ]] || { print -u2 'Использование: zsh Scripts/notarize.sh /папка/сборки /папка/результата'; exit 1; }
build_dir="${1:A}"
output_dir="${2:A}"
profile="${SSH_HUB_NOTARY_PROFILE:-SSHHub-DeveloperID-Notary}"
[[ "${SSH_HUB_SIGN_IDENTITY:-}" != '-' ]] || { print -u2 'Нотарификация требует Developer ID Application, не ad-hoc.'; exit 1; }
app="$build_dir/SSH Hub.app"
mkdir -p "$output_dir"
zsh Scripts/sign-app.sh --verify "$app"
python3 Tests/UniversalBuildTests.py "$app"
notarize() {
    local payload="$1" label="$2"
    local result="$output_dir/notarization-$label.json"
    xcrun notarytool submit "$payload" --keychain-profile "$profile" --wait --timeout 20m --output-format json > "$result"
    python3 - "$result" <<'PYNOTARY'
import json,pathlib,sys
result=json.loads(pathlib.Path(sys.argv[1]).read_text())
print('Notarization:',result.get('id'),result.get('status'))
assert result.get('status')=='Accepted', 'Apple has not accepted this submission; inspect its notarytool log before distributing'
PYNOTARY
}
# Staple the app first so both the ZIP and the final DMG contain an offline ticket.
app_zip="$output_dir/notarization-app-upload.zip"
ditto -c -k --keepParent --norsrc --noextattr "$app" "$app_zip"
notarize "$app_zip" app
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"
python3 Tests/UniversalBuildTests.py "$app" --notarized
rm "$app_zip"
zsh Scripts/package-dmg.sh "$build_dir" "$output_dir" --skip-build
notarize "$output_dir/SSH-Hub-macOS.dmg" dmg
xcrun stapler staple "$output_dir/SSH-Hub-macOS.dmg"
xcrun stapler validate "$output_dir/SSH-Hub-macOS.dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$output_dir/SSH-Hub-macOS.dmg"
ditto -c -k --keepParent --norsrc --noextattr "$app" "$output_dir/SSH-Hub-macOS.zip"
(cd "$output_dir"; shasum -a 256 SSH-Hub-macOS.zip SSH-Hub-macOS.dmg > SHA256SUMS)
print -- "Подписано Developer ID, нотарифицировано и проверено Gatekeeper: $output_dir"
