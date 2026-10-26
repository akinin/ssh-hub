#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
zsh ./Scripts/sign-app.sh --check
if command -v rustup >/dev/null 2>&1; then
    rust_cargo="$(rustup which cargo)"
    export PATH="${rust_cargo:h}:$PATH"
fi
native_arch="$(uname -m)"
[[ "$native_arch" == arm64 || "$native_arch" == x86_64 ]] || exit 1
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
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" Sources/SSHHub/ApplicationDefaults.swift Tests/ApplicationDefaultsTests.swift -o "$build_dir/defaults-tests"
"$build_dir/defaults-tests"
swiftc -swift-version 5 -module-cache-path "$build_dir/module-cache" Sources/SSHHub/SSHConfig.swift Tests/Tests.swift -o "$build_dir/config-tests"
"$build_dir/config-tests"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" Sources/SSHHub/SSHConfig.swift Sources/SSHHub/PasswordToolsView.swift Sources/SSHHub/AppAccess.swift Tests/PasswordToolsTests.swift -o "$build_dir/password-tools-tests" -framework SwiftUI -framework Security -framework LocalAuthentication
"$build_dir/password-tools-tests"
swiftc -swift-version 5 -module-cache-path "$build_dir/module-cache" Sources/SSHHub/SSHConfig.swift Sources/SSHHub/ConfigChanges.swift Sources/SSHHub/ConnectionProbe.swift Tests/FeatureTests.swift -o "$build_dir/feature-tests"
"$build_dir/feature-tests"
swiftc -swift-version 5 -module-cache-path "$build_dir/module-cache" Sources/SSHHub/SSHConfig.swift Sources/SSHHub/ConfigChanges.swift Sources/SSHHub/ConnectionAppearance.swift Sources/SSHHub/AliasTransfer.swift Sources/SSHHub/LocalConnections.swift Sources/SSHHub/PublicKeys.swift Sources/SSHHub/TerminalLauncher.swift Sources/SSHHub/RecentConnections.swift Tests/ExtendedTests.swift -o "$build_dir/extended-tests" -framework AppKit
"$build_dir/extended-tests"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" Sources/SSHHub/SSHConfig.swift Sources/SSHHub/ConfigChanges.swift Sources/SSHHub/ConnectionAppearance.swift Sources/SSHHub/AliasTransfer.swift Sources/SSHHub/LocalConnections.swift Sources/SSHHub/PublicKeys.swift Sources/SSHHub/HubFeatureStorage.swift Sources/SSHHub/SSHInstalledAccess.swift Tests/SSHInstalledAccessTests.swift -o "$build_dir/ssh-installed-access-tests" -framework AppKit
"$build_dir/ssh-installed-access-tests"
swiftc -swift-version 5 -module-cache-path "$build_dir/module-cache" Sources/SSHHub/SSHConfig.swift Sources/SSHHub/ConfigChanges.swift Sources/SSHHub/ConnectionAppearance.swift Sources/SSHHub/ConnectionLogo.swift Sources/SSHHub/AliasTransfer.swift Sources/SSHHub/LocalConnections.swift Tests/ConnectionAppearanceTests.swift -o "$build_dir/appearance-tests" -framework AppKit
"$build_dir/appearance-tests"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" Sources/SSHHub/SSHConfig.swift Sources/SSHHub/ConfigChanges.swift Sources/SSHHub/ConnectionAppearance.swift Sources/SSHHub/AliasTransfer.swift Sources/SSHHub/LocalConnections.swift Sources/SSHHub/RecordTrash.swift Tests/RecordTrashTests.swift -o "$build_dir/trash-tests" -framework AppKit
"$build_dir/trash-tests"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" Sources/SSHHub/SSHConfig.swift Sources/SSHHub/ConnectionAppearance.swift Sources/SSHHub/ConnectionLogo.swift Tests/WebsiteIconTests.swift -o "$build_dir/website-icon-tests" -framework AppKit
python3 Tests/WebsiteIconIntegrationTests.py "$build_dir/website-icon-tests"
swiftc -parse-as-library -swift-version 5 -D WEB_LOGIN_TEST -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" Sources/SSHHub/SSHConfig.swift Sources/SSHHub/ConfigChanges.swift Sources/SSHHub/ConnectionAppearance.swift Sources/SSHHub/AliasTransfer.swift Sources/SSHHub/LocalConnections.swift Sources/SSHHub/SSHCredentials.swift Sources/SSHHub/WebLogin.swift Sources/SSHHub/WebLoginPicker.swift Sources/SSHHub/WebPageModel.swift Tests/WebLoginTests.swift -o "$build_dir/web-login-tests" -framework AppKit -framework WebKit
python3 Tests/WebLoginIntegrationTests.py "$build_dir/web-login-tests"
swiftc -swift-version 5 -module-cache-path "$build_dir/module-cache" Sources/SSHHub/SSHConfig.swift Sources/SSHHub/ConfigChanges.swift Sources/SSHHub/RecentConnections.swift Sources/SSHHub/QuickAliasSearch.swift Tests/QuickAliasSearchTests.swift -o "$build_dir/quick-search-tests"
"$build_dir/quick-search-tests"
swiftc -swift-version 5 -module-cache-path "$build_dir/module-cache" Sources/SSHHub/SSHConfig.swift Sources/SSHHub/ConfigChanges.swift Sources/SSHHub/ConnectionProbe.swift Sources/SSHHub/Tunnels.swift Sources/SSHHub/SSHCredentials.swift Sources/SSHHub/TunnelManager.swift Tests/TunnelTests.swift -o "$build_dir/tunnel-tests" -framework AppKit -framework Security
"$build_dir/tunnel-tests"
swiftc -swift-version 5 -module-cache-path "$build_dir/module-cache" Sources/SSHHub/SSHConfig.swift Sources/SSHHub/ConnectionProbe.swift Sources/SSHHub/Tunnels.swift Sources/SSHHub/SFTP.swift Tests/SFTPTests.swift -o "$build_dir/sftp-tests"
"$build_dir/sftp-tests"
swiftc -swift-version 5 -module-cache-path "$build_dir/module-cache" Sources/SSHHub/Integration.swift Tests/IntegrationTests.swift -o "$build_dir/integration-tests"
"$build_dir/integration-tests"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" Sources/SSHHub/ConnectionDocumentation.swift Sources/SSHHub/DocumentationMarkdown.swift Tests/DocumentationTests.swift -o "$build_dir/documentation-tests"
"$build_dir/documentation-tests"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" Sources/SSHHub/DocumentationMarkdown.swift Sources/SSHHub/DocumentationVisualPage.swift Tests/DocumentationVisualTests.swift -o "$build_dir/documentation-visual-tests" -framework AppKit -framework WebKit
"$build_dir/documentation-visual-tests"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" Sources/SSHHub/TopologyData.swift Tests/TopologyDataTests.swift -o "$build_dir/topology-data-tests"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" Sources/SSHHub/TopologyCanvasSelection.swift Tests/TopologyCanvasSelectionTests.swift -o "$build_dir/topology-selection-tests"
"$build_dir/topology-selection-tests"
swiftc -parse-as-library -swift-version 5 -D TOPOLOGY_PROVIDER_TEST -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" Sources/SSHHub/SSHConfig.swift Sources/SSHHub/ConfigChanges.swift Sources/SSHHub/ConnectionProbe.swift Sources/SSHHub/Tunnels.swift Sources/SSHHub/SSHCredentials.swift Sources/SSHHub/ToolkitRuntime.swift Sources/SSHHub/TLSSOCKSBridge.swift Sources/SSHHub/SSHLoginPolicy.swift Sources/SSHHub/Nmap.swift Sources/SSHHub/TCPAvailability.swift Sources/SSHHub/TopologyData.swift Sources/SSHHub/IPCalculator.swift Sources/SSHHub/TopologyProvider.swift Sources/SSHHub/TopologyProviderMapping.swift Tests/TopologyProviderTests.swift -o "$build_dir/topology-provider-tests" -framework AppKit -framework Security
"$build_dir/topology-provider-tests"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" Sources/SSHHub/TopologyData.swift Sources/SSHHub/TopologyExport.swift Tests/TopologyExportTests.swift -o "$build_dir/topology-export-tests" -framework AppKit -framework CoreText
"$build_dir/topology-export-tests"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" Sources/SSHHub/SSHConfig.swift Sources/SSHHub/ConfigChanges.swift Sources/SSHHub/ConnectionAppearance.swift Sources/SSHHub/LocalConnections.swift Sources/SSHHub/TopologyData.swift Sources/SSHHub/TopologyRecordSeed.swift Tests/TopologyRecordSeedTests.swift -o "$build_dir/topology-record-seed-tests"
"$build_dir/topology-record-seed-tests"
"$build_dir/topology-data-tests"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" Sources/SSHHub/TopologyData.swift Sources/SSHHub/TopologySSH.swift Tests/TopologySSHTests.swift -o "$build_dir/topology-ssh-tests"
"$build_dir/topology-ssh-tests"
swiftc -parse-as-library -swift-version 5 -D TOPOLOGY_UNIFI_TEST -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" Sources/SSHHub/TopologyData.swift Sources/SSHHub/TopologyUniFi.swift Tests/TopologyUniFiTests.swift -o "$build_dir/topology-unifi-tests" -framework Security -framework LocalAuthentication
"$build_dir/topology-unifi-tests"
swiftc -parse-as-library -swift-version 5 -D TOPOLOGY_UNIFI_TEST -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" Sources/SSHHub/TopologyData.swift Sources/SSHHub/TopologyUniFi.swift Sources/SSHHub/TopologyRouterAPI.swift Tests/TopologyRouterAPITests.swift -o "$build_dir/topology-router-tests" -framework Security -framework LocalAuthentication
"$build_dir/topology-router-tests"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" Sources/SSHHub/SSHConfig.swift Sources/SSHHub/ConfigChanges.swift Sources/SSHHub/ConnectionProbe.swift Sources/SSHHub/Tunnels.swift Sources/SSHHub/SSHCredentials.swift Sources/SSHHub/ToolkitRuntime.swift Sources/SSHHub/TLSSOCKSBridge.swift Sources/SSHHub/SSHLoginPolicy.swift Sources/SSHHub/Nmap.swift Sources/SSHHub/TCPAvailability.swift Sources/SSHHub/TopologyData.swift Sources/SSHHub/TopologySSH.swift Sources/SSHHub/TopologyUniFi.swift Sources/SSHHub/TopologyRouterAPI.swift Sources/SSHHub/IPCalculator.swift Sources/SSHHub/ExtraTools.swift Sources/SSHHub/TopologyProvider.swift Sources/SSHHub/TopologyProviderMapping.swift Sources/SSHHub/TopologyModel.swift Tests/TopologyModelTests.swift -o "$build_dir/topology-model-tests" -framework Security -framework AppKit -framework LocalAuthentication
"$build_dir/topology-model-tests"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" Sources/SSHHub/TabInformation.swift Tests/TabInformationTests.swift -o "$build_dir/tab-information-tests"
"$build_dir/tab-information-tests"
swiftc -parse-as-library -swift-version 5 -DREMOTE_LOGS_TEST -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" Sources/SSHHub/RemoteLogs.swift Tests/RemoteLogsTests.swift -o "$build_dir/remote-logs-tests"
"$build_dir/remote-logs-tests"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" Sources/SSHHub/RecordInventory.swift Tests/RecordInventoryTests.swift -o "$build_dir/inventory-tests"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" Sources/SSHHub/SSHConfig.swift Sources/SSHHub/ConfigChanges.swift Sources/SSHHub/ConnectionAppearance.swift Sources/SSHHub/ConnectionIcon.swift Sources/SSHHub/InterfaceChrome.swift Sources/SSHHub/ConnectionProbe.swift Sources/SSHHub/Tunnels.swift Sources/SSHHub/SSHCredentials.swift Sources/SSHHub/ToolkitRuntime.swift Sources/SSHHub/TLSSOCKSBridge.swift Sources/SSHHub/SSHLoginPolicy.swift Sources/SSHHub/RecordInventory.swift Sources/SSHHub/RecordInventoryView.swift Tests/InventoryIntegrationTests.swift -o "$build_dir/inventory-integration-tests" -framework AppKit -framework SwiftUI
python3 Tests/InventoryIntegrationTests.py "$build_dir/inventory-integration-tests"
"$build_dir/inventory-tests"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" Sources/SSHHub/SSHConfig.swift Sources/SSHHub/ConfigChanges.swift Sources/SSHHub/ConnectionProbe.swift Sources/SSHHub/Tunnels.swift Sources/SSHHub/SSHCredentials.swift Sources/SSHHub/ToolkitRuntime.swift Sources/SSHHub/TLSSOCKSBridge.swift Sources/SSHHub/SSHLoginPolicy.swift Sources/SSHHub/ConnectionTunnel.swift Sources/SSHHub/WinboxSettings.swift Sources/SSHHub/Winbox.swift Tests/WinboxTests.swift -o "$build_dir/winbox-tests" -framework AppKit -framework Security
"$build_dir/winbox-tests"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" Sources/SSHHub/SSHConfig.swift Sources/SSHHub/ConfigChanges.swift Sources/SSHHub/ConnectionAppearance.swift Sources/SSHHub/AliasTransfer.swift Sources/SSHHub/LocalConnections.swift Sources/SSHHub/ConnectionAttachments.swift Sources/SSHHub/ConsoleLaunch.swift Sources/SSHHub/TerminalLauncher.swift Sources/SSHHub/PublicKeys.swift Tests/RecordTests.swift -o "$build_dir/record-tests" -framework AppKit
"$build_dir/record-tests"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" Sources/SSHHub/SSHConfig.swift Sources/SSHHub/ConnectionAppearance.swift Sources/SSHHub/RecordTOTP.swift Tests/RecordTOTPTests.swift -o "$build_dir/totp-tests" -framework Security -framework LocalAuthentication
"$build_dir/totp-tests"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" Sources/SSHHub/SSHConfig.swift Sources/SSHHub/ConfigChanges.swift Sources/SSHHub/HubFeatureStorage.swift Sources/SSHHub/Nuclei.swift Tests/NucleiTests.swift -o "$build_dir/nuclei-tests"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" Sources/SSHHub/SSHConfig.swift Sources/SSHHub/ConfigChanges.swift Sources/SSHHub/ConnectionProbe.swift Sources/SSHHub/Tunnels.swift Sources/SSHHub/SSHCredentials.swift Sources/SSHHub/ToolkitRuntime.swift Sources/SSHHub/TLSSOCKSBridge.swift Sources/SSHHub/SSHLoginPolicy.swift Sources/SSHHub/NucleiRoute.swift Tests/NucleiRouteTests.swift -o "$build_dir/nuclei-route-tests" -framework AppKit -framework Security -framework LocalAuthentication
"$build_dir/nuclei-route-tests"
"$build_dir/nuclei-tests"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" Sources/SSHHub/SSHConfig.swift Sources/SSHHub/ConfigChanges.swift Sources/SSHHub/Nmap.swift Sources/SSHHub/Nuclei.swift Sources/SSHHub/HubFeatureStorage.swift Sources/SSHHub/SecurityChecks.swift Sources/SSHHub/SecurityRemote.swift Sources/SSHHub/SecurityIntelligence.swift Sources/SSHHub/SecurityAssessment.swift Tests/SecurityChecksTests.swift -o "$build_dir/security-checks-tests"
"$build_dir/security-checks-tests"
python3 Tests/SecurityChecksIntegrationTests.py "$build_dir/security-checks-tests"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" Sources/SSHHub/SSHConfig.swift Sources/SSHHub/ConfigChanges.swift Sources/SSHHub/ConnectionAppearance.swift Sources/SSHHub/AliasTransfer.swift Sources/SSHHub/LocalConnections.swift Sources/SSHHub/IPCalculator.swift Sources/SSHHub/RecordDiscoveryData.swift Sources/SSHHub/RecordTCPDiscovery.swift Sources/SSHHub/Nmap.swift Sources/SSHHub/Nuclei.swift Sources/SSHHub/HubFeatureStorage.swift Sources/SSHHub/SecurityChecks.swift Sources/SSHHub/SecurityRemote.swift Sources/SSHHub/SecurityIntelligence.swift Sources/SSHHub/SecurityAssessment.swift Tests/SecurityAssessmentTests.swift -o "$build_dir/security-assessment-tests" -framework AppKit -framework SystemConfiguration
"$build_dir/security-assessment-tests"
python3 Tests/RecordTCPDiscoveryIntegrationTests.py "$build_dir/security-assessment-tests"
python3 Tests/SecurityIntelIntegrationTests.py "$build_dir/security-assessment-tests"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" Sources/SSHHub/SSHConfig.swift Sources/SSHHub/ConfigChanges.swift Sources/SSHHub/ConnectionAppearance.swift Sources/SSHHub/AliasTransfer.swift Sources/SSHHub/LocalConnections.swift Sources/SSHHub/Nmap.swift Tests/TransportTests.swift -o "$build_dir/transport-tests"
"$build_dir/transport-tests"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" Sources/SSHHub/ReleaseUpdate.swift Tests/UpdateTests.swift -o "$build_dir/update-tests"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" Sources/SSHHub/SSHConfig.swift Sources/SSHHub/CommandTask.swift Sources/SSHHub/SigningCertificate.swift Tests/SigningCertificateTests.swift -o "$build_dir/signing-certificate-tests" -framework Security
"$build_dir/signing-certificate-tests"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" Sources/SSHHub/UpdateTermination.swift Tests/UpdateTerminationTests.swift -framework AppKit -o "$build_dir/update-quit-tests"
"$build_dir/update-quit-tests"
"$build_dir/update-quit-tests" --later
"$build_dir/update-quit-tests" --later --timeout
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" Sources/SSHHub/WorkspaceDivider.swift Tests/WorkspaceDividerTests.swift -o "$build_dir/workspace-divider-tests" -framework AppKit -framework SwiftUI
"$build_dir/workspace-divider-tests"
# The 3.0 feature checks use synthetic metadata and owned loopback/process fixtures.
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" Sources/SSHHub/SSHConfig.swift Sources/SSHHub/SSHCredentials.swift Sources/SSHHub/SharedCredentials.swift Sources/SSHHub/KDBX.swift Sources/SSHHub/InterfaceChrome.swift Sources/SSHHub/KDBXEditorView.swift Sources/SSHHub/KDBXView.swift Sources/SSHHub/SharedCredentialsView.swift Sources/SSHHub/PasswordToolsView.swift Tests/SharedCredentialsTests.swift -o "$build_dir/shared-credentials-tests" -framework AppKit -framework Security -framework LocalAuthentication
"$build_dir/shared-credentials-tests"
maintenance_sources=(Sources/SSHHub/SSHConfig.swift Sources/SSHHub/ConfigChanges.swift Sources/SSHHub/WorkspaceProfiles.swift Sources/SSHHub/ConnectionAppearance.swift Sources/SSHHub/ConnectionTree.swift Sources/SSHHub/AliasTransfer.swift Sources/SSHHub/LocalConnections.swift Sources/SSHHub/SavedCommands.swift Sources/SSHHub/HubFeatureStorage.swift Sources/SSHHub/SSHCredentials.swift Sources/SSHHub/ToolkitRuntime.swift Sources/SSHHub/TLSSOCKSBridge.swift Sources/SSHHub/Tunnels.swift Sources/SSHHub/ConnectionProbe.swift Sources/SSHHub/TerminalLauncher.swift Sources/SSHHub/PublicKeys.swift Sources/SSHHub/SSHLoginPolicy.swift Sources/SSHHub/Maintenance.swift)
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" "${maintenance_sources[@]}" Tests/MaintenanceTests.swift -o "$build_dir/maintenance-tests" -framework AppKit -framework Security -framework LocalAuthentication
"$build_dir/maintenance-tests"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" "${maintenance_sources[@]}" Sources/SSHHub/AssistantDiagnostics.swift Sources/SSHHub/DiagnosticHistory.swift Tests/AssistantDiagnosticsTests.swift -o "$build_dir/assistant-diagnostics-tests" -framework AppKit -framework Security -framework LocalAuthentication
"$build_dir/assistant-diagnostics-tests"
infrastructure_sources=(Sources/SSHHub/SSHConfig.swift Sources/SSHHub/ConfigChanges.swift Sources/SSHHub/ConnectionAppearance.swift Sources/SSHHub/LocalConnections.swift Sources/SSHHub/RecordInventory.swift Sources/SSHHub/TopologyData.swift Sources/SSHHub/TopologyRecordSeed.swift Sources/SSHHub/ConnectionProbe.swift Sources/SSHHub/Tunnels.swift Sources/SSHHub/SSHCredentials.swift Sources/SSHHub/ToolkitRuntime.swift Sources/SSHHub/TLSSOCKSBridge.swift Sources/SSHHub/SSHLoginPolicy.swift Sources/SSHHub/InfrastructureIntegrations.swift)
swiftc -parse-as-library -swift-version 5 -D INFRASTRUCTURE_TEST -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" "${infrastructure_sources[@]}" Sources/SSHHub/InfrastructureIntegrationsView.swift Tests/InfrastructureIntegrationTests.swift -o "$build_dir/infrastructure-tests" -framework AppKit -framework Security -framework LocalAuthentication
"$build_dir/infrastructure-tests"
python3 Tests/InfrastructureIntegrationTests.py "$build_dir/infrastructure-tests"
monitoring_sources=(Sources/SSHHub/InterfaceChrome.swift Sources/SSHHub/SSHConfig.swift Sources/SSHHub/ConfigChanges.swift Sources/SSHHub/ConnectionAppearance.swift Sources/SSHHub/AliasTransfer.swift Sources/SSHHub/LocalConnections.swift Sources/SSHHub/ConnectionTree.swift Sources/SSHHub/WorkspaceProfiles.swift Sources/SSHHub/WorkspaceLayout.swift Sources/SSHHub/WorkspaceSnapshot.swift Sources/SSHHub/SavedCommands.swift Sources/SSHHub/SSHCredentials.swift Sources/SSHHub/SSHLoginPolicy.swift Sources/SSHHub/ConnectionProbe.swift Sources/SSHHub/Tunnels.swift Sources/SSHHub/ConnectionTunnel.swift Sources/SSHHub/ToolkitRuntime.swift Sources/SSHHub/TLSSOCKSBridge.swift Sources/SSHHub/HubFeatureStorage.swift Sources/SSHHub/Maintenance.swift Sources/SSHHub/TCPAvailability.swift Sources/SSHHub/Monitoring.swift Sources/SSHHub/MonitoringInstallation.swift Sources/SSHHub/MonitoringView.swift Sources/SSHHub/MonitoringInstallationView.swift)
swiftc -parse-as-library -swift-version 5 -D MONITORING_TEST -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" "${monitoring_sources[@]}" Tests/MonitoringTests.swift -o "$build_dir/monitoring-tests" -framework SwiftUI -framework UserNotifications
swiftc -parse-as-library -swift-version 5 -D MONITORING_TEST -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" "${monitoring_sources[@]}" Tests/MonitoringInstallationTests.swift -o "$build_dir/monitoring-installation-tests" -framework SwiftUI -framework UserNotifications
"$build_dir/monitoring-installation-tests"
swiftc -parse-as-library -swift-version 5 -D MONITORING_TEST -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" "${monitoring_sources[@]}" Sources/SSHHub/LoginNotifications.swift Sources/SSHHub/LoginNotificationsView.swift Tests/LoginNotificationTests.swift -o "$build_dir/login-notification-tests" -framework SwiftUI -framework UserNotifications
"$build_dir/login-notification-tests"
PYTHONDONTWRITEBYTECODE=1 python3 LoginNotifications/test_manage.py
PYTHONDONTWRITEBYTECODE=1 python3 LoginNotifications/test_notify.py
python3 MonitoringCollector/test_install.py
python3 MonitoringCollector/test_collector.py "$build_dir/monitoring-tests"
swiftc -parse-as-library -swift-version 5 -D ASSISTANT_TEST -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" Sources/SSHHub/SSHConfig.swift Sources/SSHHub/AIAssistant.swift Tests/AIAssistantIntegrationTests.swift -o "$build_dir/assistant-integration-tests" -framework Security
"$build_dir/assistant-integration-tests"
python3 Tests/AIAssistantIntegrationTests.py "$build_dir/assistant-integration-tests"
operations_sources=(Sources/SSHHub/SSHConfig.swift Sources/SSHHub/ConfigChanges.swift Sources/SSHHub/ConnectionAppearance.swift Sources/SSHHub/AliasTransfer.swift Sources/SSHHub/LocalConnections.swift Sources/SSHHub/WorkspaceProfiles.swift Sources/SSHHub/ConnectionTree.swift Sources/SSHHub/HubFeatureStorage.swift Sources/SSHHub/GlobalSearch.swift Sources/SSHHub/ConnectionDocumentation.swift Sources/SSHHub/ConnectionAttachments.swift Sources/SSHHub/SavedCommands.swift Sources/SSHHub/SessionJournal.swift Sources/SSHHub/AIAssistant.swift)
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" "${operations_sources[@]}" Tests/OperationsTests.swift -o "$build_dir/operations-tests" -framework Security
"$build_dir/operations-tests"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" "${operations_sources[@]}" Tests/GlobalSearchSafetyTests.swift -o "$build_dir/search-safety-tests" -framework Security
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" "${operations_sources[@]}" Sources/SSHHub/SSHCredentials.swift Sources/SSHHub/SharedCredentials.swift Sources/SSHHub/RecordBatch.swift Tests/RecordBatchTests.swift -o "$build_dir/record-batch-tests" -framework AppKit -framework Security -framework LocalAuthentication
"$build_dir/record-batch-tests"
"$build_dir/search-safety-tests"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" Sources/SSHHub/SSHConfig.swift Sources/SSHHub/HubFeatureStorage.swift Sources/SSHHub/AIAssistant.swift Sources/SSHHub/TCPAvailability.swift Sources/SSHHub/AssistantChat.swift Tests/AssistantChatTests.swift -o "$build_dir/assistant-chat-tests" -framework Security
"$build_dir/assistant-chat-tests"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" Sources/SSHHub/SSHConfig.swift Sources/SSHHub/ConnectionDocumentation.swift Sources/SSHHub/AssistantActions.swift Tests/AssistantActionsTests.swift -o "$build_dir/assistant-actions-tests"
"$build_dir/assistant-actions-tests"
backup_operations_sources=(Sources/SSHHub/SSHConfig.swift Sources/SSHHub/ConfigChanges.swift Sources/SSHHub/ConnectionAppearance.swift Sources/SSHHub/AliasTransfer.swift Sources/SSHHub/LocalConnections.swift Sources/SSHHub/WorkspaceProfiles.swift Sources/SSHHub/ConnectionTree.swift Sources/SSHHub/HubFeatureStorage.swift Sources/SSHHub/GlobalSearch.swift Sources/SSHHub/ConnectionDocumentation.swift Sources/SSHHub/ConnectionAttachments.swift Sources/SSHHub/SavedCommands.swift Sources/SSHHub/SessionJournal.swift Sources/SSHHub/AIAssistant.swift Sources/SSHHub/Maintenance.swift Sources/SSHHub/SSHCredentials.swift Sources/SSHHub/SharedCredentials.swift Sources/SSHHub/SSHLoginPolicy.swift Sources/SSHHub/ToolkitRuntime.swift Sources/SSHHub/TLSSOCKSBridge.swift Sources/SSHHub/Tunnels.swift Sources/SSHHub/ConnectionProbe.swift Sources/SSHHub/InfrastructureIntegrations.swift Sources/SSHHub/RecordInventory.swift Sources/SSHHub/TopologyData.swift Sources/SSHHub/TopologyRecordSeed.swift Sources/SSHHub/Monitoring.swift Sources/SSHHub/MonitoringInstallation.swift Sources/SSHHub/ConnectionTunnel.swift Sources/SSHHub/WorkspaceLayout.swift Sources/SSHHub/WorkspaceSnapshot.swift Sources/SSHHub/TCPAvailability.swift Sources/SSHHub/AssistantChat.swift Sources/SSHHub/BackupOperations.swift)
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" "${backup_operations_sources[@]}" Tests/BackupOperationsTests.swift -o "$build_dir/backup-operations-tests" -framework AppKit -framework Security -framework LocalAuthentication -framework UserNotifications
"$build_dir/backup-operations-tests"
app_dir="$build_dir/SSH Hub.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
# Isolated KeePass reader/editor: fixed dependency graph; no external runtime on the user's Mac.
export CARGO_TARGET_DIR="$build_dir/kdbx-target"
export MACOSX_DEPLOYMENT_TARGET=14.0
SSH_HUB_KDBX_FIXTURE="$build_dir/kdbx-fixtures" cargo test --locked --manifest-path KDBXHelper/Cargo.toml
native_rust_target="$(rustc -vV | sed -n 's/^host: //p')"
cargo build --locked --release --target "$native_rust_target" --manifest-path KDBXHelper/Cargo.toml
cp "$CARGO_TARGET_DIR/$native_rust_target/release/ssh-hub-kdbx" "$app_dir/Contents/MacOS/SSHKDBX"
python3 KDBXHelper/test_interop.py "$app_dir/Contents/MacOS/SSHKDBX"
python3 KDBXHelper/test_write_interop.py "$app_dir/Contents/MacOS/SSHKDBX"
python3 KDBXHelper/licenses.py "$app_dir/Contents/Resources/KDBX-LICENSES.txt"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" Sources/SSHHub/SSHConfig.swift Sources/SSHHub/SSHCredentials.swift Sources/SSHHub/SharedCredentials.swift Sources/SSHHub/KDBX.swift Sources/SSHHub/HubFeatureStorage.swift Sources/SSHHub/KDBXRecordLinks.swift Tests/KDBXTests.swift -o "$build_dir/kdbx-tests" -framework AppKit -framework Security -framework LocalAuthentication
"$build_dir/kdbx-tests" "$app_dir/Contents/MacOS/SSHKDBX"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" "${infrastructure_sources[@]}" Sources/SSHHub/ConnectionDocumentation.swift Sources/SSHHub/ConnectionAttachments.swift Sources/SSHHub/RecordFeatureTags.swift Tests/RecordFeatureTagsTests.swift -o "$build_dir/record-feature-tests" -framework AppKit -framework Security
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
zsh Scripts/build-wireguard.sh "$build_dir"
cp "$build_dir/SSHWG" "$app_dir/Contents/MacOS/SSHWG"
cp "$build_dir/WireGuard-LICENSES.txt" "$app_dir/Contents/Resources/WireGuard-LICENSES.txt"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" Sources/SSHHub/SSHConfig.swift Sources/SSHHub/ConfigChanges.swift Sources/SSHHub/WorkspaceProfiles.swift Sources/SSHHub/ConnectionAppearance.swift Sources/SSHHub/ConnectionTree.swift Sources/SSHHub/AliasTransfer.swift Sources/SSHHub/LocalConnections.swift Sources/SSHHub/SavedCommands.swift Sources/SSHHub/HubFeatureStorage.swift Sources/SSHHub/SSHCredentials.swift Sources/SSHHub/ToolkitRuntime.swift Sources/SSHHub/TLSSOCKSBridge.swift Sources/SSHHub/Tunnels.swift Sources/SSHHub/ConnectionProbe.swift Sources/SSHHub/TerminalLauncher.swift Sources/SSHHub/PublicKeys.swift Sources/SSHHub/SSHLoginPolicy.swift Sources/SSHHub/Maintenance.swift Sources/SSHHub/SharedCredentials.swift Sources/SSHHub/KDBX.swift Sources/SSHHub/WireGuard.swift Tests/WireGuardTests.swift -o "$build_dir/wireguard-tests" -framework AppKit -framework Security -framework LocalAuthentication
"$build_dir/wireguard-tests" "$build_dir/SSHWG"
clang -arch "$native_arch" -mmacosx-version-min=14.0 -isysroot "$sdk_dir" -O2 Helpers/TelnetHelper.c -o "$app_dir/Contents/MacOS/SSHTelnet"
zsh Scripts/build-rdp.sh "${SSH_HUB_RDP_CACHE:-$build_dir/rdp}" "$app_dir/Contents/MacOS/SSHRDP" "$sdk_dir" "$build_dir/rdp-fixture"
cp "${SSH_HUB_RDP_CACHE:-$build_dir/rdp}/$native_arch/freerdp-3.32.2/LICENSE" "$app_dir/Contents/Resources/FreeRDP-LICENSE.txt"
cp "${SSH_HUB_RDP_CACHE:-$build_dir/rdp}/$native_arch/openssl-3.6.4/LICENSE.txt" "$app_dir/Contents/Resources/OpenSSL-LICENSE.txt"
swiftc -parse-as-library -swift-version 5 -O -sdk "$sdk_dir" -target "$native_arch-apple-macosx14.0" -module-cache-path "$build_dir/module-cache" Sources/SSHHub/ReleaseUpdate.swift Helpers/UpdateHelper.swift -o "$app_dir/Contents/MacOS/SSHUpdate"
swiftc -parse-as-library -swift-version 5 -O -sdk "$sdk_dir" -target "$native_arch-apple-macosx14.0" -module-cache-path "$build_dir/module-cache" Sources/SSHHub/SSHConfig.swift Helpers/SerialHelper.swift -o "$app_dir/Contents/MacOS/SSHSerial"
swiftc -swift-version 5 -O -sdk "$sdk_dir" -target "$native_arch-apple-macosx14.0" -module-cache-path "$build_dir/module-cache" Helpers/Askpass.swift -o "$app_dir/Contents/MacOS/SSHAskpass"
swiftc -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" Sources/SSHHub/SSHConfig.swift Sources/SSHHub/Keygen.swift Tests/KeygenTests.swift -o "$build_dir/keygen-tests"
"$build_dir/keygen-tests" "${app_dir:A}/Contents/MacOS/SSHAskpass"
swiftc -parse-as-library -swift-version 5 -O -sdk "$sdk_dir" -target "$native_arch-apple-macosx14.0" -module-cache-path "$build_dir/module-cache" Helpers/LoginAskpass.swift -o "$app_dir/Contents/MacOS/SSHLoginAskpass"
swiftc -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" Sources/SSHHub/SSHConfig.swift Sources/SSHHub/ConfigChanges.swift Sources/SSHHub/ConnectionAppearance.swift Sources/SSHHub/AliasTransfer.swift Sources/SSHHub/LocalConnections.swift Sources/SSHHub/PublicKeys.swift Sources/SSHHub/TerminalLauncher.swift Sources/SSHHub/ConnectionTree.swift Sources/SSHHub/ConsoleLaunch.swift Sources/SSHHub/SSHCredentials.swift Sources/SSHHub/WorkspaceProfiles.swift Sources/SSHHub/WorkspaceLayout.swift Sources/SSHHub/WorkspaceSnapshot.swift Sources/SSHHub/SavedCommands.swift Tests/WorkspaceTests.swift -o "$build_dir/workspace-tests" -framework AppKit -framework Security
"$build_dir/workspace-tests" "$app_dir/Contents/MacOS/SSHLoginAskpass"
advanced_sources=(Sources/SSHHub/SSHConfig.swift Sources/SSHHub/ConfigChanges.swift Sources/SSHHub/ConnectionAppearance.swift Sources/SSHHub/AliasTransfer.swift Sources/SSHHub/LocalConnections.swift Sources/SSHHub/ConnectionAttachments.swift Sources/SSHHub/ConnectionDocumentation.swift Sources/SSHHub/SavedCommands.swift Sources/SSHHub/ConnectionTree.swift Sources/SSHHub/WorkspaceProfiles.swift Sources/SSHHub/WorkspaceLayout.swift Sources/SSHHub/WorkspaceSnapshot.swift Sources/SSHHub/RecordTemplate.swift Sources/SSHHub/CommandLibrary.swift Sources/SSHHub/Nmap.swift Sources/SSHHub/ConnectionProbe.swift Sources/SSHHub/Tunnels.swift Sources/SSHHub/RecordInventory.swift Sources/SSHHub/WinboxSettings.swift Sources/SSHHub/TopologyData.swift Sources/SSHHub/TopologyUniFi.swift Sources/SSHHub/TopologyRouterAPI.swift Sources/SSHHub/WireGuard.swift Sources/SSHHub/PrivateMaterialFile.swift Sources/SSHHub/BackupSecrets.swift Sources/SSHHub/BackupServices.swift Sources/SSHHub/BackupArchive.swift Sources/SSHHub/BackupRestoration.swift Sources/SSHHub/TCPAvailability.swift Sources/SSHHub/SessionJournal.swift Sources/SSHHub/HubFeatureStorage.swift Sources/SSHHub/GlobalSearch.swift Sources/SSHHub/Maintenance.swift Sources/SSHHub/SSHCredentials.swift Sources/SSHHub/SharedCredentials.swift Sources/SSHHub/SSHLoginPolicy.swift Sources/SSHHub/ToolkitRuntime.swift Sources/SSHHub/TLSSOCKSBridge.swift Sources/SSHHub/InfrastructureIntegrations.swift Sources/SSHHub/TopologyRecordSeed.swift Sources/SSHHub/Monitoring.swift Sources/SSHHub/MonitoringInstallation.swift Sources/SSHHub/ConnectionTunnel.swift Sources/SSHHub/AIAssistant.swift Sources/SSHHub/AssistantChat.swift Sources/SSHHub/BackupOperations.swift)
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" "${advanced_sources[@]}" Tests/AdvancedTests.swift -o "$build_dir/advanced-tests" -framework AppKit -framework Security -framework LocalAuthentication -framework UserNotifications
"$build_dir/advanced-tests"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" "${advanced_sources[@]}" Tests/BackupServicesTests.swift -o "$build_dir/backup-services-tests" -framework AppKit -framework Security -framework LocalAuthentication -framework UserNotifications
"$build_dir/backup-services-tests" "$build_dir/SSHWG"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" Sources/SSHHub/SSHConfig.swift Sources/SSHHub/ConfigChanges.swift Sources/SSHHub/ConnectionAppearance.swift Sources/SSHHub/AliasTransfer.swift Sources/SSHHub/LocalConnections.swift Sources/SSHHub/PublicKeys.swift Sources/SSHHub/TerminalLauncher.swift Sources/SSHHub/ConsoleLaunch.swift Sources/SSHHub/ConnectionLaunch.swift Sources/SSHHub/CommandTask.swift Sources/SSHHub/RemoteFiles.swift Sources/SSHHub/VNCConnection.swift Tests/RemoteProtocolTests.swift -o "$build_dir/remote-protocol-tests" -framework AppKit
"$build_dir/remote-protocol-tests"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" Sources/SSHHub/SSHConfig.swift Sources/SSHHub/ConfigChanges.swift Sources/SSHHub/SavedCommands.swift Sources/SSHHub/ConnectionProbe.swift Sources/SSHHub/Tunnels.swift Sources/SSHHub/ToolkitRuntime.swift Sources/SSHHub/TLSSOCKSBridge.swift Sources/SSHHub/IPCalculator.swift Sources/SSHHub/Nmap.swift Sources/SSHHub/ExtraTools.swift Sources/SSHHub/TCPAvailability.swift Tests/ToolkitTests.swift -o "$build_dir/toolkit-tests" -framework Security
"$build_dir/toolkit-tests"
python3 Tests/TLSCertificateIntegrationTests.py "$build_dir/toolkit-tests"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" Sources/SSHHub/SSHConfig.swift Sources/SSHHub/ConfigChanges.swift Sources/SSHHub/ConnectionProbe.swift Sources/SSHHub/Tunnels.swift Sources/SSHHub/ToolkitRuntime.swift Sources/SSHHub/TLSSOCKSBridge.swift Sources/SSHHub/IPCalculator.swift Sources/SSHHub/Nmap.swift Sources/SSHHub/ExtraTools.swift Tests/ExtraToolsTests.swift -o "$build_dir/extra-tools-tests" -framework Security
"$build_dir/extra-tools-tests"
swiftc -parse-as-library -swift-version 5 -sdk "$sdk_dir" -module-cache-path "$build_dir/module-cache" Sources/SSHHub/MenuLayout.swift Tests/MenuLayoutTests.swift -o "$build_dir/menu-layout-tests" -framework AppKit
"$build_dir/menu-layout-tests"
spm_args=(--build-system native --scratch-path "$build_dir/spm" --cache-path "$build_dir/spm-cache" --config-path "$build_dir/spm-config" --security-path "$build_dir/spm-security" --disable-sandbox --sdk "$sdk_dir" --triple "$native_arch-apple-macosx14.0" -c release)
swift build "${spm_args[@]}" --product SSHHub
swift build "${spm_args[@]}" --product SSHHubConsoleChecks
bin_dir="$(swift build "${spm_args[@]}" --show-bin-path)"
"$bin_dir/SSHHubConsoleChecks"
cp "$bin_dir/SSHHub" "$app_dir/Contents/MacOS/SSHHub"
ditto --norsrc --noextattr "$bin_dir/SwiftTerm_SwiftTerm.bundle" "$app_dir/Contents/Resources/SwiftTerm_SwiftTerm.bundle"
cp Vendor/SwiftTerm/LICENSE "$app_dir/Contents/Resources/SwiftTerm-LICENSE.txt"

zsh ./Scripts/build-universal.sh "$build_dir" "$sdk_dir"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
cp Signing/SSHHub-CodeSigning.cer "$app_dir/Contents/Resources/SSHHub-CodeSigning.cer"
swiftc -module-cache-path "$build_dir/module-cache" Tools/Icon.swift -o "$build_dir/make-icon" -framework AppKit
"$build_dir/make-icon" "$build_dir/AppIcon.iconset"
iconutil -c icns "$build_dir/AppIcon.iconset" -o "$app_dir/Contents/Resources/AppIcon.icns"
xattr -cr "$app_dir"
zsh ./Scripts/sign-app.sh "$app_dir"
update_zip="$build_dir/update-check.zip"
ditto -c -k --keepParent --norsrc --noextattr "$app_dir" "$update_zip"
"$build_dir/update-tests" "$update_zip"
rm "$update_zip"
echo "Готово: $app_dir"
