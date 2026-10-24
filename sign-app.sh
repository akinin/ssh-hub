#!/bin/zsh
# Only the public certificate fingerprint is stored in the repository.
set -euo pipefail
script_dir="${0:A:h}"
identity="${SSH_HUB_SIGN_IDENTITY:-$(<"$script_dir/signing-identity.sha1")}"
identity="${identity:u}"

fail() { print -u2 -- "$*"; exit 1; }
if [[ "$identity" != '-' ]]; then
    [[ "$identity" =~ '^[0-9A-F]{40}$' ]] || fail 'Нужен SHA-1 сертификата подписи (40 hex) или явный SSH_HUB_SIGN_IDENTITY=- для разработки.'
    identities="$(/usr/bin/security find-identity -v -p codesigning)"
    [[ "$identities" == *" $identity "* ]] || fail "Постоянный сертификат $identity недоступен или не имеет доверия для подписи кода. Сборка остановлена; ad-hoc автоматически не используется."
fi
if [[ "${1:-}" == '--check' ]]; then
    print -- "Подпись: $identity"
    exit 0
fi
verify_only=false
if [[ "${1:-}" == '--verify' ]]; then
    verify_only=true
    shift
fi
[[ $# == 1 ]] || fail 'Использование: zsh sign-app.sh [--verify] /путь/SSH\ Hub.app | --check'
app_dir="${1:A}"
[[ -d "$app_dir" && ! -L "$1" ]] || fail 'Нужен обычный каталог приложения.'
plist="$app_dir/Contents/Info.plist"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")"
executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist")"
[[ "$bundle_id" == com.olshaniki.ssh-aliases && "$executable" == SSHHub ]] || fail 'Неожиданный идентификатор или исполняемый файл приложения.'

# Sign the contained command-line helpers first, then seal the enclosing bundle.
# Keep identifiers explicit: temporary build paths must not change the requirement.
for binary in "$app_dir/Contents/MacOS/"*(N); do
    [[ -f "$binary" && ! -L "$binary" ]] || fail "Неожиданный объект: $binary"
    [[ "$(/usr/bin/file -b "$binary")" == *Mach-O* ]] || fail "Неожиданный формат: $binary"
    [[ "${binary:t}" == "$executable" ]] && continue
    if [[ "$verify_only" == false ]]; then
        /usr/bin/codesign --force --sign "$identity" --timestamp=none --identifier "$bundle_id.helper.${binary:t}" "$binary"
    fi
done
if [[ "$verify_only" == false ]]; then
    /usr/bin/codesign --force --sign "$identity" --timestamp=none --identifier "$bundle_id" "$app_dir"
fi
/usr/bin/codesign --verify --deep --strict "$app_dir"
if [[ "$identity" != '-' ]]; then
    /usr/bin/codesign --verify --strict -R "=identifier \"$bundle_id\" and certificate leaf = H\"$identity\"" "$app_dir"
    requirement="$(/usr/bin/codesign -d -r- "$app_dir" 2>&1)"
    [[ "$requirement" != *cdhash* ]] || fail 'Идентичность приложения не должна зависеть от хеша сборки.'
    for binary in "$app_dir/Contents/MacOS/"*(N); do
        [[ "${binary:t}" == "$executable" ]] && continue
        /usr/bin/codesign --verify --strict -R "=identifier \"$bundle_id.helper.${binary:t}\" and certificate leaf = H\"$identity\"" "$binary"
    done
fi
print -- "Подпись проверена: $app_dir ($identity)"
