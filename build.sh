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
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" SSHConfig.swift PasswordToolsView.swift AppAccess.swift PasswordToolsTests.swift -o "$build_dir/password-tools-tests" -framework SwiftUI -framework Security -framework LocalAuthentication
"$build_dir/password-tools-tests"
swiftc -swift-version 5 -module-cache-path "$build_dir/module-cache" SSHConfig.swift ConfigChanges.swift ConnectionProbe.swift FeatureTests.swift -o "$build_dir/feature-tests"
"$build_dir/feature-tests"
swiftc -swift-version 5 -module-cache-path "$build_dir/module-cache" SSHConfig.swift ConfigChanges.swift ConnectionAppearance.swift AliasTransfer.swift LocalConnections.swift PublicKeys.swift TerminalLauncher.swift RecentConnections.swift ExtendedTests.swift -o "$build_dir/extended-tests" -framework AppKit
"$build_dir/extended-tests"
swiftc -swift-version 5 -module-cache-path "$build_dir/module-cache" SSHConfig.swift ConfigChanges.swift ConnectionAppearance.swift ConnectionLogo.swift AliasTransfer.swift LocalConnections.swift ConnectionAppearanceTests.swift -o "$build_dir/appearance-tests" -framework AppKit
"$build_dir/appearance-tests"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" SSHConfig.swift ConnectionAppearance.swift ConnectionLogo.swift WebsiteIconTests.swift -o "$build_dir/website-icon-tests" -framework AppKit
python3 WebsiteIconIntegrationTests.py "$build_dir/website-icon-tests"
swiftc -parse-as-library -swift-version 5 -D WEB_LOGIN_TEST -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" SSHConfig.swift ConfigChanges.swift ConnectionAppearance.swift AliasTransfer.swift LocalConnections.swift SSHCredentials.swift WebLogin.swift WebLoginPicker.swift WebPageModel.swift WebLoginTests.swift -o "$build_dir/web-login-tests" -framework AppKit -framework WebKit
python3 WebLoginIntegrationTests.py "$build_dir/web-login-tests"
swiftc -swift-version 5 -module-cache-path "$build_dir/module-cache" SSHConfig.swift ConfigChanges.swift RecentConnections.swift QuickAliasSearch.swift QuickAliasSearchTests.swift -o "$build_dir/quick-search-tests"
"$build_dir/quick-search-tests"
swiftc -swift-version 5 -module-cache-path "$build_dir/module-cache" SSHConfig.swift ConfigChanges.swift ConnectionProbe.swift Tunnels.swift SSHCredentials.swift TunnelManager.swift TunnelTests.swift -o "$build_dir/tunnel-tests" -framework AppKit -framework Security
"$build_dir/tunnel-tests"
swiftc -swift-version 5 -module-cache-path "$build_dir/module-cache" SSHConfig.swift ConnectionProbe.swift Tunnels.swift SFTP.swift SFTPTests.swift -o "$build_dir/sftp-tests"
"$build_dir/sftp-tests"
swiftc -swift-version 5 -module-cache-path "$build_dir/module-cache" Integration.swift IntegrationTests.swift -o "$build_dir/integration-tests"
"$build_dir/integration-tests"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" ConnectionDocumentation.swift DocumentationMarkdown.swift DocumentationTests.swift -o "$build_dir/documentation-tests"
"$build_dir/documentation-tests"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" DocumentationMarkdown.swift DocumentationVisualPage.swift DocumentationVisualTests.swift -o "$build_dir/documentation-visual-tests" -framework AppKit -framework WebKit
"$build_dir/documentation-visual-tests"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" TopologyData.swift TopologyDataTests.swift -o "$build_dir/topology-data-tests"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" TopologyCanvasSelection.swift TopologyCanvasSelectionTests.swift -o "$build_dir/topology-selection-tests"
"$build_dir/topology-selection-tests"
swiftc -parse-as-library -swift-version 5 -D TOPOLOGY_PROVIDER_TEST -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" SSHConfig.swift ConfigChanges.swift ConnectionProbe.swift Tunnels.swift SSHCredentials.swift ToolkitRuntime.swift SSHLoginPolicy.swift Nmap.swift TCPAvailability.swift TopologyData.swift IPCalculator.swift TopologyProvider.swift TopologyProviderMapping.swift TopologyProviderTests.swift -o "$build_dir/topology-provider-tests" -framework AppKit -framework Security
"$build_dir/topology-provider-tests"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" TopologyData.swift TopologyExport.swift TopologyExportTests.swift -o "$build_dir/topology-export-tests" -framework AppKit -framework CoreText
"$build_dir/topology-export-tests"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" SSHConfig.swift ConfigChanges.swift ConnectionAppearance.swift LocalConnections.swift TopologyData.swift TopologyRecordSeed.swift TopologyRecordSeedTests.swift -o "$build_dir/topology-record-seed-tests"
"$build_dir/topology-record-seed-tests"
"$build_dir/topology-data-tests"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" TopologyData.swift TopologySSH.swift TopologySSHTests.swift -o "$build_dir/topology-ssh-tests"
"$build_dir/topology-ssh-tests"
swiftc -parse-as-library -swift-version 5 -D TOPOLOGY_UNIFI_TEST -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" TopologyData.swift TopologyUniFi.swift TopologyUniFiTests.swift -o "$build_dir/topology-unifi-tests" -framework Security -framework LocalAuthentication
"$build_dir/topology-unifi-tests"
swiftc -parse-as-library -swift-version 5 -D TOPOLOGY_UNIFI_TEST -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" TopologyData.swift TopologyUniFi.swift TopologyRouterAPI.swift TopologyRouterAPITests.swift -o "$build_dir/topology-router-tests" -framework Security -framework LocalAuthentication
"$build_dir/topology-router-tests"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" SSHConfig.swift ConfigChanges.swift ConnectionProbe.swift Tunnels.swift SSHCredentials.swift ToolkitRuntime.swift SSHLoginPolicy.swift Nmap.swift TCPAvailability.swift TopologyData.swift TopologySSH.swift TopologyUniFi.swift TopologyRouterAPI.swift IPCalculator.swift ExtraTools.swift TopologyProvider.swift TopologyProviderMapping.swift TopologyModel.swift TopologyModelTests.swift -o "$build_dir/topology-model-tests" -framework Security -framework AppKit -framework LocalAuthentication
"$build_dir/topology-model-tests"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" TabInformation.swift TabInformationTests.swift -o "$build_dir/tab-information-tests"
"$build_dir/tab-information-tests"
swiftc -parse-as-library -swift-version 5 -DREMOTE_LOGS_TEST -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" RemoteLogs.swift RemoteLogsTests.swift -o "$build_dir/remote-logs-tests"
"$build_dir/remote-logs-tests"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" RecordInventory.swift RecordInventoryTests.swift -o "$build_dir/inventory-tests"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" SSHConfig.swift ConfigChanges.swift ConnectionAppearance.swift ConnectionIcon.swift ConnectionProbe.swift Tunnels.swift SSHCredentials.swift ToolkitRuntime.swift SSHLoginPolicy.swift RecordInventory.swift RecordInventoryView.swift InventoryIntegrationTests.swift -o "$build_dir/inventory-integration-tests" -framework AppKit -framework SwiftUI
python3 InventoryIntegrationTests.py "$build_dir/inventory-integration-tests"
"$build_dir/inventory-tests"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" SSHConfig.swift ConfigChanges.swift ConnectionProbe.swift Tunnels.swift SSHCredentials.swift ToolkitRuntime.swift SSHLoginPolicy.swift ConnectionTunnel.swift WinboxSettings.swift Winbox.swift WinboxTests.swift -o "$build_dir/winbox-tests" -framework AppKit -framework Security
"$build_dir/winbox-tests"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" SSHConfig.swift ConfigChanges.swift ConnectionAppearance.swift AliasTransfer.swift LocalConnections.swift ConnectionAttachments.swift ConsoleLaunch.swift TerminalLauncher.swift PublicKeys.swift RecordTests.swift -o "$build_dir/record-tests" -framework AppKit
"$build_dir/record-tests"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" SSHConfig.swift ConfigChanges.swift ConnectionAppearance.swift AliasTransfer.swift LocalConnections.swift Nmap.swift TransportTests.swift -o "$build_dir/transport-tests"
"$build_dir/transport-tests"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" ReleaseUpdate.swift UpdateTests.swift -o "$build_dir/update-tests"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" UpdateTermination.swift UpdateTerminationTests.swift -framework AppKit -o "$build_dir/update-quit-tests"
"$build_dir/update-quit-tests"
"$build_dir/update-quit-tests" --later
"$build_dir/update-quit-tests" --later --timeout
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" WorkspaceDivider.swift WorkspaceDividerTests.swift -o "$build_dir/workspace-divider-tests" -framework AppKit -framework SwiftUI
"$build_dir/workspace-divider-tests"
# The 3.0 feature checks use synthetic metadata and owned loopback/process fixtures.
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" SSHConfig.swift SSHCredentials.swift SharedCredentials.swift KDBX.swift InterfaceChrome.swift KDBXEditorView.swift KDBXView.swift SharedCredentialsView.swift PasswordToolsView.swift SharedCredentialsTests.swift -o "$build_dir/shared-credentials-tests" -framework AppKit -framework Security -framework LocalAuthentication
"$build_dir/shared-credentials-tests"
maintenance_sources=(SSHConfig.swift ConfigChanges.swift WorkspaceProfiles.swift ConnectionAppearance.swift ConnectionTree.swift AliasTransfer.swift LocalConnections.swift SavedCommands.swift HubFeatureStorage.swift SSHCredentials.swift ToolkitRuntime.swift Tunnels.swift ConnectionProbe.swift TerminalLauncher.swift PublicKeys.swift SSHLoginPolicy.swift Maintenance.swift)
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" "${maintenance_sources[@]}" MaintenanceTests.swift -o "$build_dir/maintenance-tests" -framework AppKit -framework Security -framework LocalAuthentication
"$build_dir/maintenance-tests"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" "${maintenance_sources[@]}" AssistantDiagnostics.swift DiagnosticHistory.swift AssistantDiagnosticsTests.swift -o "$build_dir/assistant-diagnostics-tests" -framework AppKit -framework Security -framework LocalAuthentication
"$build_dir/assistant-diagnostics-tests"
infrastructure_sources=(SSHConfig.swift ConfigChanges.swift ConnectionAppearance.swift LocalConnections.swift RecordInventory.swift TopologyData.swift TopologyRecordSeed.swift ConnectionProbe.swift Tunnels.swift SSHCredentials.swift ToolkitRuntime.swift SSHLoginPolicy.swift InfrastructureIntegrations.swift)
swiftc -parse-as-library -swift-version 5 -D INFRASTRUCTURE_TEST -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" "${infrastructure_sources[@]}" InfrastructureIntegrationsView.swift InfrastructureIntegrationTests.swift -o "$build_dir/infrastructure-tests" -framework AppKit -framework Security -framework LocalAuthentication
"$build_dir/infrastructure-tests"
python3 InfrastructureIntegrationTests.py "$build_dir/infrastructure-tests"
monitoring_sources=(SSHConfig.swift ConfigChanges.swift ConnectionAppearance.swift AliasTransfer.swift LocalConnections.swift ConnectionTree.swift WorkspaceProfiles.swift WorkspaceLayout.swift WorkspaceSnapshot.swift SavedCommands.swift SSHCredentials.swift SSHLoginPolicy.swift ConnectionProbe.swift Tunnels.swift ConnectionTunnel.swift ToolkitRuntime.swift HubFeatureStorage.swift Maintenance.swift TCPAvailability.swift Monitoring.swift MonitoringInstallation.swift MonitoringView.swift MonitoringInstallationView.swift)
swiftc -parse-as-library -swift-version 5 -D MONITORING_TEST -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" "${monitoring_sources[@]}" MonitoringTests.swift -o "$build_dir/monitoring-tests" -framework SwiftUI -framework UserNotifications
swiftc -parse-as-library -swift-version 5 -D MONITORING_TEST -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" "${monitoring_sources[@]}" MonitoringInstallationTests.swift -o "$build_dir/monitoring-installation-tests" -framework SwiftUI -framework UserNotifications
"$build_dir/monitoring-installation-tests"
swiftc -parse-as-library -swift-version 5 -D MONITORING_TEST -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" "${monitoring_sources[@]}" LoginNotifications.swift LoginNotificationsView.swift LoginNotificationTests.swift -o "$build_dir/login-notification-tests" -framework SwiftUI -framework UserNotifications
"$build_dir/login-notification-tests"
PYTHONDONTWRITEBYTECODE=1 python3 LoginNotifications/test_manage.py
PYTHONDONTWRITEBYTECODE=1 python3 LoginNotifications/test_notify.py
python3 MonitoringCollector/test_install.py
python3 MonitoringCollector/test_collector.py "$build_dir/monitoring-tests"
swiftc -parse-as-library -swift-version 5 -D ASSISTANT_TEST -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" SSHConfig.swift AIAssistant.swift AIAssistantIntegrationTests.swift -o "$build_dir/assistant-integration-tests" -framework Security
"$build_dir/assistant-integration-tests"
python3 AIAssistantIntegrationTests.py "$build_dir/assistant-integration-tests"
operations_sources=(SSHConfig.swift ConfigChanges.swift ConnectionAppearance.swift AliasTransfer.swift LocalConnections.swift WorkspaceProfiles.swift ConnectionTree.swift HubFeatureStorage.swift GlobalSearch.swift ConnectionDocumentation.swift ConnectionAttachments.swift SavedCommands.swift SessionJournal.swift AIAssistant.swift)
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" "${operations_sources[@]}" OperationsTests.swift -o "$build_dir/operations-tests" -framework Security
"$build_dir/operations-tests"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" "${operations_sources[@]}" GlobalSearchSafetyTests.swift -o "$build_dir/search-safety-tests" -framework Security
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" "${operations_sources[@]}" SSHCredentials.swift SharedCredentials.swift RecordBatch.swift RecordBatchTests.swift -o "$build_dir/record-batch-tests" -framework AppKit -framework Security -framework LocalAuthentication
"$build_dir/record-batch-tests"
"$build_dir/search-safety-tests"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" SSHConfig.swift HubFeatureStorage.swift AIAssistant.swift TCPAvailability.swift AssistantChat.swift AssistantChatTests.swift -o "$build_dir/assistant-chat-tests" -framework Security
"$build_dir/assistant-chat-tests"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" SSHConfig.swift ConnectionDocumentation.swift AssistantActions.swift AssistantActionsTests.swift -o "$build_dir/assistant-actions-tests"
"$build_dir/assistant-actions-tests"
backup_operations_sources=(SSHConfig.swift ConfigChanges.swift ConnectionAppearance.swift AliasTransfer.swift LocalConnections.swift WorkspaceProfiles.swift ConnectionTree.swift HubFeatureStorage.swift GlobalSearch.swift ConnectionDocumentation.swift ConnectionAttachments.swift SavedCommands.swift SessionJournal.swift AIAssistant.swift Maintenance.swift SSHCredentials.swift SharedCredentials.swift SSHLoginPolicy.swift ToolkitRuntime.swift Tunnels.swift ConnectionProbe.swift InfrastructureIntegrations.swift RecordInventory.swift TopologyData.swift TopologyRecordSeed.swift Monitoring.swift MonitoringInstallation.swift ConnectionTunnel.swift WorkspaceLayout.swift WorkspaceSnapshot.swift TCPAvailability.swift AssistantChat.swift BackupOperations.swift)
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" "${backup_operations_sources[@]}" BackupOperationsTests.swift -o "$build_dir/backup-operations-tests" -framework AppKit -framework Security -framework LocalAuthentication -framework UserNotifications
"$build_dir/backup-operations-tests"
app_dir="$build_dir/SSH Hub.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
# Isolated KeePass reader/editor: fixed dependency graph; no external runtime on the user's Mac.
export CARGO_TARGET_DIR="$build_dir/kdbx-target"
export MACOSX_DEPLOYMENT_TARGET=14.0
SSH_HUB_KDBX_FIXTURE="$build_dir/kdbx-fixtures" cargo test --locked --manifest-path KDBXHelper/Cargo.toml
cargo build --locked --release --manifest-path KDBXHelper/Cargo.toml
cp "$CARGO_TARGET_DIR/release/ssh-hub-kdbx" "$app_dir/Contents/MacOS/SSHKDBX"
python3 KDBXHelper/test_interop.py "$app_dir/Contents/MacOS/SSHKDBX"
python3 KDBXHelper/test_write_interop.py "$app_dir/Contents/MacOS/SSHKDBX"
python3 KDBXHelper/licenses.py "$app_dir/Contents/Resources/KDBX-LICENSES.txt"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" SSHConfig.swift SSHCredentials.swift SharedCredentials.swift KDBX.swift KDBXTests.swift -o "$build_dir/kdbx-tests" -framework AppKit -framework Security -framework LocalAuthentication
"$build_dir/kdbx-tests" "$app_dir/Contents/MacOS/SSHKDBX"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" "${infrastructure_sources[@]}" ConnectionDocumentation.swift ConnectionAttachments.swift RecordFeatureTags.swift RecordFeatureTagsTests.swift -o "$build_dir/record-feature-tests" -framework AppKit -framework Security
"$build_dir/record-feature-tests"

# Keep the deployment kit exact: test fixtures and Python bytecode do not ship.
rm -rf "$app_dir/Contents/Resources/MonitoringCollector"
mkdir -p "$app_dir/Contents/Resources/MonitoringCollector"
for collector_file in collector.py install.py config.example.json ssh-hub-monitor.service Caddyfile.example README.md; do
    cp "MonitoringCollector/$collector_file" "$app_dir/Contents/Resources/MonitoringCollector/$collector_file"
done
rm -rf "$app_dir/Contents/Resources/LoginNotifications"
mkdir -p "$app_dir/Contents/Resources/LoginNotifications"
for notification_file in manage.py notify.py; do
    cp "LoginNotifications/$notification_file" "$app_dir/Contents/Resources/LoginNotifications/$notification_file"
done
clang -arch arm64 -mmacosx-version-min=14.0 -isysroot "$sdk_dir" -O2 TelnetHelper.c -o "$app_dir/Contents/MacOS/SSHTelnet"
zsh build-rdp.sh "${SSH_HUB_RDP_CACHE:-$build_dir/rdp}" "$app_dir/Contents/MacOS/SSHRDP" "$sdk_dir" "$build_dir/rdp-fixture"
cp "${SSH_HUB_RDP_CACHE:-$build_dir/rdp}/freerdp-3.32.2/LICENSE" "$app_dir/Contents/Resources/FreeRDP-LICENSE.txt"
cp "${SSH_HUB_RDP_CACHE:-$build_dir/rdp}/openssl-3.6.4/LICENSE.txt" "$app_dir/Contents/Resources/OpenSSL-LICENSE.txt"
swiftc -parse-as-library -swift-version 5 -O -sdk "$sdk_dir" -target arm64-apple-macosx14.0 -module-cache-path "$build_dir/module-cache" ReleaseUpdate.swift UpdateHelper.swift -o "$app_dir/Contents/MacOS/SSHUpdate"
swiftc -parse-as-library -swift-version 5 -O -sdk "$sdk_dir" -target arm64-apple-macosx14.0 -module-cache-path "$build_dir/module-cache" SSHConfig.swift SerialHelper.swift -o "$app_dir/Contents/MacOS/SSHSerial"
swiftc -swift-version 5 -O -sdk "$sdk_dir" -target arm64-apple-macosx14.0 -module-cache-path "$build_dir/module-cache" Askpass.swift -o "$app_dir/Contents/MacOS/SSHAskpass"
swiftc -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" SSHConfig.swift Keygen.swift KeygenTests.swift -o "$build_dir/keygen-tests"
"$build_dir/keygen-tests" "${app_dir:A}/Contents/MacOS/SSHAskpass"
swiftc -parse-as-library -swift-version 5 -O -sdk "$sdk_dir" -target arm64-apple-macosx14.0 -module-cache-path "$build_dir/module-cache" LoginAskpass.swift -o "$app_dir/Contents/MacOS/SSHLoginAskpass"
swiftc -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" SSHConfig.swift ConfigChanges.swift ConnectionAppearance.swift AliasTransfer.swift LocalConnections.swift PublicKeys.swift TerminalLauncher.swift ConnectionTree.swift ConsoleLaunch.swift SSHCredentials.swift WorkspaceProfiles.swift WorkspaceLayout.swift WorkspaceSnapshot.swift SavedCommands.swift WorkspaceTests.swift -o "$build_dir/workspace-tests" -framework AppKit -framework Security
"$build_dir/workspace-tests" "$app_dir/Contents/MacOS/SSHLoginAskpass"
advanced_sources=(SSHConfig.swift ConfigChanges.swift ConnectionAppearance.swift AliasTransfer.swift LocalConnections.swift ConnectionAttachments.swift ConnectionDocumentation.swift SavedCommands.swift ConnectionTree.swift WorkspaceProfiles.swift WorkspaceLayout.swift WorkspaceSnapshot.swift RecordTemplate.swift CommandLibrary.swift Nmap.swift ConnectionProbe.swift Tunnels.swift RecordInventory.swift WinboxSettings.swift TopologyData.swift BackupArchive.swift BackupRestoration.swift TCPAvailability.swift SessionJournal.swift HubFeatureStorage.swift GlobalSearch.swift Maintenance.swift SSHCredentials.swift SharedCredentials.swift SSHLoginPolicy.swift ToolkitRuntime.swift InfrastructureIntegrations.swift TopologyRecordSeed.swift Monitoring.swift MonitoringInstallation.swift ConnectionTunnel.swift AIAssistant.swift AssistantChat.swift BackupOperations.swift)
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" "${advanced_sources[@]}" AdvancedTests.swift -o "$build_dir/advanced-tests" -framework AppKit -framework Security -framework LocalAuthentication -framework UserNotifications
"$build_dir/advanced-tests"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" SSHConfig.swift ConfigChanges.swift ConnectionAppearance.swift AliasTransfer.swift LocalConnections.swift PublicKeys.swift TerminalLauncher.swift ConsoleLaunch.swift ConnectionLaunch.swift CommandTask.swift RemoteFiles.swift VNCConnection.swift RemoteProtocolTests.swift -o "$build_dir/remote-protocol-tests" -framework AppKit
"$build_dir/remote-protocol-tests"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" SSHConfig.swift ConfigChanges.swift SavedCommands.swift ConnectionProbe.swift Tunnels.swift ToolkitRuntime.swift IPCalculator.swift Nmap.swift ExtraTools.swift TCPAvailability.swift ToolkitTests.swift -o "$build_dir/toolkit-tests" -framework Security
"$build_dir/toolkit-tests"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" SSHConfig.swift ConfigChanges.swift ConnectionProbe.swift Tunnels.swift ToolkitRuntime.swift IPCalculator.swift Nmap.swift ExtraTools.swift ExtraToolsTests.swift -o "$build_dir/extra-tools-tests" -framework Security
"$build_dir/extra-tools-tests"
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
