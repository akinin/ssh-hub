#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
source_cache="${1:A}"
output="${2:A}"
sdk="${3:-$(xcrun --show-sdk-path)}"
architecture="${SSH_HUB_ARCH:-$(uname -m)}"
[[ "$architecture" == arm64 || "$architecture" == x86_64 ]] || { print -u2 'Неизвестная архитектура RDP'; exit 1; }
cache_dir="$source_cache/$architecture"
mkdir -p "$cache_dir"
cmake_bin="$(command -v cmake || true)"
[[ -n "$cmake_bin" ]] || { print -u2 'Для сборки RDP нужен CMake.'; exit 1; }
fetch_source() {
  local file="$1" checksum="$2" url="$3"
  if [[ ! -f "$source_cache/$file" ]]; then
    curl --fail --location --retry 3 "$url" -o "$source_cache/$file.partial.$$"
    [[ "$(shasum -a 256 "$source_cache/$file.partial.$$" | cut -d ' ' -f 1)" == "$checksum" ]] || { print -u2 "Неверная SHA-256: $file"; exit 1; }
    mv "$source_cache/$file.partial.$$" "$source_cache/$file"
  fi
  [[ "$(shasum -a 256 "$source_cache/$file" | cut -d ' ' -f 1)" == "$checksum" ]] || { print -u2 "Неверная SHA-256: $file"; exit 1; }
}
fetch_source freerdp-3.32.2.tar.gz e95a505c0057e4d06a3b120477c421028769deba4db9c639ef3465d050f0955c https://github.com/FreeRDP/FreeRDP/releases/download/3.32.2/freerdp-3.32.2.tar.gz
fetch_source openssl-3.6.4.tar.gz 9bffaa1ad1e07b354c21bd3324ec02fa15579f45a7d0494b3e74bc449b7333ef https://github.com/openssl/openssl/releases/download/openssl-3.6.4/openssl-3.6.4.tar.gz
if [[ ! -f "$cache_dir/openssl-3.6.4/libssl.a" || ! -f "$cache_dir/openssl-3.6.4/include/openssl/macros.h" || ! -f "$cache_dir/openssl-3.6.4/include/openssl/md4.h" ]]; then
  tar -xzf "$source_cache/openssl-3.6.4.tar.gz" -C "$cache_dir"
  (cd "$cache_dir/openssl-3.6.4"; ./Configure "darwin64-$architecture-cc" no-shared no-tests no-module --openssldir=/etc/ssl -mmacosx-version-min=14.0 -isysroot "$sdk"; make -j6 build_libs)
fi
if [[ ! -f "$cache_dir/freerdp-3.32.2/CMakeLists.txt" ]]; then tar -xzf "$source_cache/freerdp-3.32.2.tar.gz" -C "$cache_dir"; fi
"$cmake_bin" -S "$cache_dir/freerdp-3.32.2" -B "$cache_dir/build" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCMAKE_OSX_ARCHITECTURES="$architecture" -DCMAKE_OSX_SYSROOT="$sdk" \
  -DCMAKE_EXPORT_NO_PACKAGE_REGISTRY=ON -DCMAKE_EXPORT_PACKAGE_REGISTRY=OFF \
  -DBUILD_SHARED_LIBS=OFF -DWITH_CLIENT_COMMON=ON -DWITH_CLIENT=OFF -DWITH_SERVER=ON -DWITH_PROXY=OFF -DWITH_SHADOW=OFF -DWITH_PLATFORM_SERVER=OFF -DWITH_CHANNELS=ON -DWITH_CLIENT_CHANNELS=ON -DWITH_SERVER_CHANNELS=ON \
  -DWITH_SAMPLE=OFF -DWITH_FFMPEG=OFF -DWITH_SWSCALE=OFF -DWITH_OPENH264=OFF -DWITH_JPEG=OFF -DWITH_X11=OFF -DWITH_WAYLAND=OFF \
  -DWITH_KRB5=OFF -DWITH_GSSAPI=OFF -DWITH_AAD=OFF -DWITH_PKCS11=OFF -DWITH_SMARTCARD_PCSC=OFF -DWITH_PCSC=OFF \
  -DCHANNEL_AINPUT=OFF -DCHANNEL_AUDIN=OFF -DCHANNEL_ECHO=OFF -DCHANNEL_ENCOMSP=OFF -DCHANNEL_GEOMETRY=OFF -DCHANNEL_GFXREDIR=OFF -DCHANNEL_LOCATION=OFF -DCHANNEL_PARALLEL=OFF -DCHANNEL_PRINTER=OFF -DCHANNEL_RAIL=OFF -DCHANNEL_RDP2TCP=OFF -DCHANNEL_RDPECAM=OFF -DCHANNEL_RDPEAR=OFF -DCHANNEL_RDPEI=OFF -DCHANNEL_RDPEMSC=OFF -DCHANNEL_RDPEWA=OFF -DCHANNEL_RDPGFX=OFF -DCHANNEL_RDPSND=OFF -DCHANNEL_REMDESK=OFF -DCHANNEL_SERIAL=OFF -DCHANNEL_SMARTCARD=OFF -DCHANNEL_SSHAGENT=OFF -DCHANNEL_TELEMETRY=OFF -DCHANNEL_TSMF=OFF -DCHANNEL_URBDRC=OFF -DCHANNEL_VIDEO=OFF -DCHANNEL_CLIPRDR=ON -DCHANNEL_DISP=ON -DCHANNEL_DRDYNVC=ON -DCHANNEL_RDPDR=ON -DCHANNEL_DRIVE=ON -DWITH_FUSE=OFF -DWITH_CUPS=OFF -DWITH_WINPR_TOOLS=OFF -DWITH_MANPAGES=OFF -DWITH_JSON_DISABLED=ON -DWITH_INTERNAL_MD4=ON -DWITH_INTERNAL_RC4=ON \
  -DOPENSSL_INCLUDE_DIR="$cache_dir/openssl-3.6.4/include" -DOPENSSL_SSL_LIBRARY="$cache_dir/openssl-3.6.4/libssl.a" \
  -DOPENSSL_CRYPTO_LIBRARY="$cache_dir/openssl-3.6.4/libcrypto.a" -DOPENSSL_USE_STATIC_LIBS=ON
"$cmake_bin" --build "$cache_dir/build" -j6 --target freerdp-client freerdp-server
compile_bridge() {
local -a extra_sources extra_libraries
if [[ "$1" == Helpers/RDP/RDPHelper.c ]]; then extra_sources=(Helpers/RDP/RDPChannels.c); else extra_sources=(Tests/RDPFixtureChannels.c); extra_libraries=("$cache_dir/build/server/common/libfreerdp-server3.a"); fi
clang -arch "$architecture" -mmacosx-version-min=14.0 -isysroot "$sdk" -O2 -Wno-deprecated-declarations \
  -I"$cache_dir/freerdp-3.32.2/include" -I"$cache_dir/freerdp-3.32.2/winpr/include" \
  -I"$cache_dir/build/include" -I"$cache_dir/build/winpr/include" \
  "$1" "${extra_sources[@]}" "${extra_libraries[@]}" "$cache_dir/build/client/common/libfreerdp-client3.a" "$cache_dir/build/libfreerdp/libfreerdp3.a" "$cache_dir/build/winpr/libwinpr/libwinpr3.a" \
  "$cache_dir/openssl-3.6.4/libssl.a" "$cache_dir/openssl-3.6.4/libcrypto.a" \
  -lz -liconv -framework Foundation -framework Security -framework CoreServices -o "$2"
}
compile_bridge Helpers/RDP/RDPHelper.c "$output"
if [[ -n "${4:-}" ]]; then compile_bridge Tests/RDPFixture.c "${4:A}"; fi
# No runtime dependency on Homebrew or a build-machine path.
if otool -L "$output" | tail -n +2 | rg '/opt/homebrew|/usr/local|/private/tmp'; then print -u2 'Непереносимая зависимость RDP'; exit 1; fi
