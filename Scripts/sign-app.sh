#!/bin/zsh
# The private Developer ID key stays in the login Keychain.
set -euo pipefail
repo_root="${0:A:h:h}"
identity="${SSH_HUB_SIGN_IDENTITY:-$(<"$repo_root/Signing/signing-identity.sha1")}"
identity="${identity:u}"
team_id="$(<"$repo_root/Signing/developer-team-id.txt")"
profile="${SSH_HUB_PROVISIONING_PROFILE:-$repo_root/Signing/SSHHub.provisionprofile}"
fail() { print -u2 -- "$*"; exit 1; }
[[ "$team_id" =~ '^[A-Z0-9]{10}$' ]] || fail 'Некорректный Apple Developer Team ID.'
verify_only=false
if [[ "${1:-}" == '--verify' ]]; then verify_only=true; shift; fi
if [[ "$identity" != '-' ]]; then
    [[ "$identity" =~ '^[0-9A-F]{40}$' ]] || fail 'Нужен SHA-1 Developer ID Application или явный SSH_HUB_SIGN_IDENTITY=- для разработки.'
    if [[ "$verify_only" == false ]]; then
        identities="$(/usr/bin/security find-identity -v -p codesigning)"
        identity_line="$(print -r -- "$identities" | awk -v digest="$identity" '$2 == digest { print; exit }')"
        [[ "$identity_line" == *'"Developer ID Application: '*"($team_id)"* ]] || fail "Developer ID Application $identity команды $team_id недоступен. Сборка остановлена; ad-hoc автоматически не используется."
    fi
fi
if [[ "$identity" != '-' && "$verify_only" == false ]]; then
    python3 "$repo_root/Scripts/signing-profile.py" --profile "$profile" --identity "$identity"
fi
if [[ "${1:-}" == '--check' ]]; then print -- "Developer ID: $identity · Team $team_id"; exit 0; fi
[[ $# == 1 ]] || fail 'Использование: zsh Scripts/sign-app.sh [--verify] /путь/SSH\ Hub.app | --check'
app_dir="${1:A}"
[[ -d "$app_dir" && ! -L "$1" ]] || fail 'Нужен обычный каталог приложения.'
plist="$app_dir/Contents/Info.plist"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")"
executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist")"
[[ "$bundle_id" == com.olshaniki.ssh-aliases && "$executable" == SSHHub ]] || fail 'Неожиданный идентификатор приложения.'
sign_flags=(--options runtime --timestamp)
[[ "$identity" == '-' ]] && sign_flags=(--timestamp=none)
requirement() {
    print -r -- "=identifier \"$1\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$team_id\""
}
# Sign inside out, without --deep signing or broadened entitlements.
for binary in "$app_dir/Contents/MacOS/"*(N); do
    [[ -f "$binary" && ! -L "$binary" && "${binary:t}" =~ '^[A-Za-z0-9]+$' ]] || fail "Неожиданный объект: $binary"
    [[ "$(/usr/bin/file -b "$binary")" == *Mach-O* ]] || fail "Неожиданный формат: $binary"
    [[ "${binary:t}" == "$executable" ]] && continue
    if [[ "$verify_only" == false ]]; then
        /usr/bin/codesign --force --sign "$identity" "${sign_flags[@]}" --identifier "$bundle_id.helper.${binary:t}" "$binary"
    fi
done
if [[ "$verify_only" == false ]]; then
    if [[ "$identity" != '-' ]]; then
        cp "$profile" "$app_dir/Contents/embedded.provisionprofile"
        /usr/bin/codesign --force --sign "$identity" "${sign_flags[@]}" --identifier "$bundle_id" --entitlements "$repo_root/Signing/SSHHub.entitlements" "$app_dir"
    else
        /usr/bin/codesign --force --sign "$identity" "${sign_flags[@]}" --identifier "$bundle_id" "$app_dir"
    fi
fi
/usr/bin/codesign --verify --deep --strict "$app_dir"
if [[ "$identity" != '-' ]]; then
    python3 "$repo_root/Scripts/signing-profile.py" --app "$app_dir" --identity "$identity"
    /usr/bin/codesign --verify --strict -R "$(requirement "$bundle_id")" "$app_dir"
    for binary in "$app_dir/Contents/MacOS/"*(N); do
        binary_id="$bundle_id.helper.${binary:t}"
        [[ "${binary:t}" == "$executable" ]] && binary_id="$bundle_id"
        /usr/bin/codesign --verify --strict -R "$(requirement "$binary_id")" "$binary"
        metadata="$(/usr/bin/codesign -d --verbose=4 "$binary" 2>&1)"
        [[ "$metadata" == *'(runtime)'* && "$metadata" == *'Timestamp='* ]] || fail "Нужны Hardened Runtime и secure timestamp: $binary"
        designated="$(/usr/bin/codesign -d -r- "$binary" 2>&1)"
        [[ "$designated" != *cdhash* ]] || fail 'Идентичность не должна зависеть от хеша сборки.'
    done
fi
if [[ "$identity" == '-' ]]; then
    print -- "Локальная ad-hoc подпись проверена (только разработка): $app_dir"
else
    print -- "Подпись проверена: $app_dir (Developer ID $team_id)"
fi
