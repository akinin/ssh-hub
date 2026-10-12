#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
build_dir="${1:-build}"
mkdir -p "$build_dir/module-cache"
build_dir="${build_dir:A}"
# The macOS 27 beta SDK shipped without the SwiftUI State macro plugin in CLT.
# Prefer the installed stable SDK when available; the app supports macOS 14+.
sdk_dir="$(xcrun --show-sdk-path)"
if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
    sdk_dir=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
export SDKROOT="$sdk_dir"
export CLANG_MODULE_CACHE_PATH="$build_dir/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$build_dir/module-cache"
swiftc -swift-version 5 -module-cache-path "$build_dir/module-cache" SSHConfig.swift Tests.swift -o "$build_dir/config-tests"
"$build_dir/config-tests"
swiftc -swift-version 5 -module-cache-path "$build_dir/module-cache" SSHConfig.swift ConfigChanges.swift ConnectionProbe.swift FeatureTests.swift -o "$build_dir/feature-tests"
"$build_dir/feature-tests"
swiftc -swift-version 5 -module-cache-path "$build_dir/module-cache" SSHConfig.swift ConfigChanges.swift ConnectionAppearance.swift AliasTransfer.swift PublicKeys.swift TerminalLauncher.swift RecentConnections.swift ExtendedTests.swift -o "$build_dir/extended-tests" -framework AppKit
"$build_dir/extended-tests"
swiftc -swift-version 5 -module-cache-path "$build_dir/module-cache" SSHConfig.swift ConfigChanges.swift ConnectionAppearance.swift ConnectionLogo.swift AliasTransfer.swift ConnectionAppearanceTests.swift -o "$build_dir/appearance-tests" -framework AppKit
"$build_dir/appearance-tests"
swiftc -swift-version 5 -module-cache-path "$build_dir/module-cache" SSHConfig.swift ConfigChanges.swift RecentConnections.swift QuickAliasSearch.swift QuickAliasSearchTests.swift -o "$build_dir/quick-search-tests"
"$build_dir/quick-search-tests"
swiftc -swift-version 5 -module-cache-path "$build_dir/module-cache" SSHConfig.swift ConfigChanges.swift ConnectionProbe.swift Tunnels.swift TunnelManager.swift TunnelTests.swift -o "$build_dir/tunnel-tests"
"$build_dir/tunnel-tests"
swiftc -swift-version 5 -module-cache-path "$build_dir/module-cache" SSHConfig.swift ConnectionProbe.swift Tunnels.swift SFTP.swift SFTPTests.swift -o "$build_dir/sftp-tests"
"$build_dir/sftp-tests"
swiftc -swift-version 5 -module-cache-path "$build_dir/module-cache" Integration.swift IntegrationTests.swift -o "$build_dir/integration-tests"
"$build_dir/integration-tests"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" ConnectionDocumentation.swift DocumentationMarkdown.swift DocumentationTests.swift -o "$build_dir/documentation-tests"
"$build_dir/documentation-tests"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" SSHConfig.swift ConfigChanges.swift ConnectionAppearance.swift AliasTransfer.swift LocalConnections.swift ConnectionAttachments.swift ConsoleLaunch.swift TerminalLauncher.swift PublicKeys.swift RecordTests.swift -o "$build_dir/record-tests" -framework AppKit
"$build_dir/record-tests"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" SSHConfig.swift ConfigChanges.swift ConnectionAppearance.swift AliasTransfer.swift LocalConnections.swift Nmap.swift TransportTests.swift -o "$build_dir/transport-tests"
"$build_dir/transport-tests"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" ReleaseUpdate.swift UpdateTests.swift -o "$build_dir/update-tests"
app_dir="$build_dir/SSH Hub.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
swiftc -parse-as-library -swift-version 5 -O -sdk "$sdk_dir" -target arm64-apple-macosx14.0 -module-cache-path "$build_dir/module-cache" ReleaseUpdate.swift UpdateHelper.swift -o "$app_dir/Contents/MacOS/SSHUpdate"
swiftc -parse-as-library -swift-version 5 -O -sdk "$sdk_dir" -target arm64-apple-macosx14.0 -module-cache-path "$build_dir/module-cache" SSHConfig.swift SerialHelper.swift -o "$app_dir/Contents/MacOS/SSHSerial"
swiftc -swift-version 5 -O -sdk "$sdk_dir" -target arm64-apple-macosx14.0 -module-cache-path "$build_dir/module-cache" Askpass.swift -o "$app_dir/Contents/MacOS/SSHAskpass"
swiftc -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" SSHConfig.swift Keygen.swift KeygenTests.swift -o "$build_dir/keygen-tests"
"$build_dir/keygen-tests" "${app_dir:A}/Contents/MacOS/SSHAskpass"
swiftc -parse-as-library -swift-version 5 -O -sdk "$sdk_dir" -target arm64-apple-macosx14.0 -module-cache-path "$build_dir/module-cache" LoginAskpass.swift -o "$app_dir/Contents/MacOS/SSHLoginAskpass"
swiftc -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" SSHConfig.swift ConfigChanges.swift ConnectionAppearance.swift AliasTransfer.swift PublicKeys.swift TerminalLauncher.swift ConnectionTree.swift ConsoleLaunch.swift SSHCredentials.swift WorkspaceLayout.swift SavedCommands.swift WorkspaceTests.swift -o "$build_dir/workspace-tests" -framework AppKit -framework Security
"$build_dir/workspace-tests" "$app_dir/Contents/MacOS/SSHLoginAskpass"
spm_args=(--build-system native --scratch-path "$build_dir/spm" --cache-path "$build_dir/spm-cache" --config-path "$build_dir/spm-config" --security-path "$build_dir/spm-security" --disable-sandbox --sdk "$sdk_dir" --triple arm64-apple-macosx14.0 -c release)
swift build "${spm_args[@]}" --product SSHHub
swift build "${spm_args[@]}" --product SSHHubConsoleChecks
bin_dir="$(swift build "${spm_args[@]}" --show-bin-path)"
"$bin_dir/SSHHubConsoleChecks"
cp "$bin_dir/SSHHub" "$app_dir/Contents/MacOS/SSHHub"
ditto --norsrc --noextattr "$bin_dir/SwiftTerm_SwiftTerm.bundle" "$app_dir/Contents/Resources/SwiftTerm_SwiftTerm.bundle"
cp Vendor/SwiftTerm/LICENSE "$app_dir/Contents/Resources/SwiftTerm-LICENSE.txt"

cp Info.plist "$app_dir/Contents/Info.plist"
swiftc -module-cache-path "$build_dir/module-cache" Icon.swift -o "$build_dir/make-icon" -framework AppKit
"$build_dir/make-icon" "$build_dir/AppIcon.iconset"
iconutil -c icns "$build_dir/AppIcon.iconset" -o "$app_dir/Contents/Resources/AppIcon.icns"
xattr -cr "$app_dir"
codesign --force --deep --sign - "$app_dir"
update_zip="$build_dir/update-check.zip"
ditto -c -k --keepParent --norsrc --noextattr "$app_dir" "$update_zip"
"$build_dir/update-tests" "$update_zip"
rm "$update_zip"
echo "Готово: $app_dir"
