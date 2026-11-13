//
//  SettingsView.swift
//  Soduto
//
//  Copyright © 2026 Soduto. All rights reserved.
//

import SwiftUI

/// Bridges the settings that live outside `UserDefaults.standard` keys (login item, Sparkle) to SwiftUI.
@MainActor
final class SettingsModel: ObservableObject {
    private let config: Configuration?
    private let updateManager: UpdateManager?

    let hostName: String
    let onEditRunCommands: () -> Void
    let onOpenDashboard: () -> Void

    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue else { return }
            config?.launchOnLogin = launchAtLogin
            // Registration can fail (e.g. app not in /Applications); reflect what macOS actually did
            let actual = config?.launchOnLogin ?? false
            if actual != launchAtLogin {
                DispatchQueue.main.async { [weak self] in self?.launchAtLogin = actual }
            }
        }
    }

    @Published var checksForUpdatesAutomatically: Bool {
        didSet { updateManager?.automaticallyChecksForUpdates = checksForUpdatesAutomatically }
    }

    init(config: Configuration?, updateManager: UpdateManager?, onEditRunCommands: @escaping () -> Void, onOpenDashboard: @escaping () -> Void) {
        self.config = config
        self.updateManager = updateManager
        self.hostName = config?.hostDeviceName ?? Host.current().localizedName ?? "This Mac"
        self.onEditRunCommands = onEditRunCommands
        self.onOpenDashboard = onOpenDashboard
        self.launchAtLogin = config?.launchOnLogin ?? false
        self.checksForUpdatesAutomatically = updateManager?.automaticallyChecksForUpdates ?? false
    }

    /// Re-reads values that can change outside the window (e.g. "Launch on Login" in the menu bar menu)
    func reload() {
        launchAtLogin = config?.launchOnLogin ?? false
        checksForUpdatesAutomatically = updateManager?.automaticallyChecksForUpdates ?? false
    }
}

/// Soduto's Settings window: a grouped form in the style of System Settings.
/// Devices (pairing, unpairing, discovery, reconnecting) are managed in the Dashboard.
struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    @AppStorage(AppDefaultsStore.Preferences.deviceTypeKey) private var deviceType = 0
    @AppStorage(AppDefaultsStore.Preferences.disableSharePopUpKey) private var sendToOnlyDevice = false
    @AppStorage(AppDefaultsStore.Preferences.MenuBar.showDeviceIconKey) private var showDeviceIcon = false
    @AppStorage(AppDefaultsStore.Preferences.MenuBar.showBatteryKey) private var showBattery = false
    @AppStorage(AppDefaultsStore.Preferences.MenuBar.showSignalKey) private var showSignal = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Name", value: model.hostName)
                Picker("Show This Mac As", selection: $deviceType) {
                    Label("Desktop", systemImage: DeviceType.Desktop.sfSymbolName).tag(0)
                    Label("Laptop", systemImage: DeviceType.Laptop.sfSymbolName).tag(1)
                    Label("Phone", systemImage: DeviceType.Phone.sfSymbolName).tag(2)
                    Label("Tablet", systemImage: DeviceType.Tablet.sfSymbolName).tag(3)
                    Label("TV", systemImage: DeviceType.TV.sfSymbolName).tag(4)
                }
            } header: {
                Text("This Mac")
            } footer: {
                Text("Your devices see this name and icon. The name is this Mac's name in General › About; changes reach devices the next time they connect.")
                    .foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Open at Login", isOn: $model.launchAtLogin)
                Toggle("Check for Updates Automatically", isOn: $model.checksForUpdatesAutomatically)
                Toggle(isOn: $sendToOnlyDevice) {
                    Text("Send Dropped Items Without Asking")
                    Text("When only one device is connected, items dropped on the menu bar icon go straight to it.")
                }
            }

            Section {
                Toggle("Device Icon", isOn: $showDeviceIcon)
                Toggle("Battery Level", isOn: $showBattery)
                Toggle("Signal Strength", isOn: $showSignal)
            } header: {
                Text("Menu Bar")
            } footer: {
                Text("Shown while exactly one device is connected. With no device or several, the menu bar shows the Soduto icon.")
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent {
                    Button("Edit Commands…", action: model.onEditRunCommands)
                } label: {
                    Text("Run Commands")
                    Text("Commands your devices can run on this Mac.")
                }
                LabeledContent {
                    Button("Open Dashboard", action: model.onOpenDashboard)
                } label: {
                    Text("Devices")
                    Text("Pair, unpair and reconnect devices in the Dashboard.")
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, idealWidth: 500, minHeight: 420, idealHeight: 620)
    }
}
