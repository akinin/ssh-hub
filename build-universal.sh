#!/bin/zsh
# Merge the already-tested native build with a separately compiled second slice.
set -euo pipefail
cd "${0:A:h}"
if command -v rustup >/dev/null 2>&1; then
    rust_cargo="$(rustup which cargo)"
    export PATH="${rust_cargo:h}:$PATH"
fi
build_dir="${1:A}"
sdk="${2:-$(xcrun --show-sdk-path)}"
native="$(uname -m)"
case "$native" in
    arm64) other=x86_64; rust_target=x86_64-apple-darwin ;;
    x86_64) other=arm64; rust_target=aarch64-apple-darwin ;;
    *) print -u2 'Неизвестная архитектура Mac'; exit 1 ;;
esac
app="$build_dir/SSH Hub.app"
slice="$build_dir/universal/$other"
mkdir -p "$slice" "$build_dir/module-cache"
export SDKROOT="$sdk" MACOSX_DEPLOYMENT_TARGET=14.0
export CLANG_MODULE_CACHE_PATH="$build_dir/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$build_dir/module-cache"
spm_args=(--build-system native --scratch-path "$build_dir/spm-$other" --cache-path "$build_dir/spm-cache" --config-path "$build_dir/spm-config" --security-path "$build_dir/spm-security" --disable-sandbox --sdk "$sdk" --triple "$other-apple-macosx14.0" -c release)
swift build "${spm_args[@]}" --product SSHHub
bin_dir="$(swift build "${spm_args[@]}" --show-bin-path)"
cp "$bin_dir/SSHHub" "$slice/SSHHub"
export CARGO_TARGET_DIR="$build_dir/kdbx-target"
cargo build --locked --release --target "$rust_target" --manifest-path KDBXHelper/Cargo.toml
cp "$CARGO_TARGET_DIR/$rust_target/release/ssh-hub-kdbx" "$slice/SSHKDBX"
SSH_HUB_ARCH="$other" zsh build-rdp.sh "${SSH_HUB_RDP_CACHE:-$build_dir/rdp}" "$slice/SSHRDP" "$sdk"
clang -arch "$other" -mmacosx-version-min=14.0 -isysroot "$sdk" -O2 TelnetHelper.c -o "$slice/SSHTelnet"
common=(-swift-version 5 -O -sdk "$sdk" -target "$other-apple-macosx14.0" -module-cache-path "$build_dir/module-cache")
swiftc -parse-as-library "${common[@]}" ReleaseUpdate.swift UpdateHelper.swift -o "$slice/SSHUpdate"
swiftc -parse-as-library "${common[@]}" SSHConfig.swift SerialHelper.swift -o "$slice/SSHSerial"
swiftc "${common[@]}" Askpass.swift -o "$slice/SSHAskpass"
swiftc -parse-as-library "${common[@]}" LoginAskpass.swift -o "$slice/SSHLoginAskpass"
for binary in "$app/Contents/MacOS/"*(N); do
    if lipo "$binary" -verify_arch arm64 2>/dev/null && lipo "$binary" -verify_arch x86_64 2>/dev/null; then continue; fi
    lipo "$binary" -verify_arch "$native"
    lipo "$slice/${binary:t}" -verify_arch "$other"
    lipo -create "$binary" "$slice/${binary:t}" -output "$slice/${binary:t}.universal"
    mv "$slice/${binary:t}.universal" "$binary"
done
for binary in "$app/Contents/MacOS/"*(N); do
    lipo "$binary" -verify_arch arm64
    lipo "$binary" -verify_arch x86_64
done
print -- 'Все исполняемые файлы содержат arm64 и x86_64.'
