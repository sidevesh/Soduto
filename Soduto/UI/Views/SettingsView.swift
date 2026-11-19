//
//  SettingsView.swift
//  Soduto
//
//  Copyright © 2026 Soduto. All rights reserved.
//

import SwiftUI

/// Shared state for the Settings tabs: settings that live outside `UserDefaults.standard` keys (login
/// item, Sparkle) and the paired devices offered as screen-edge targets.
@MainActor
final class SettingsModel: ObservableObject {
    struct PairedDevice: Identifiable, Hashable {
        let id: Device.Id
        let name: String
        let isConnected: Bool
        let supportsEdgeControl: Bool
    }

    private let config: Configuration?
    private let updateManager: UpdateManager?
    private weak var deviceDataSource: DeviceDataSource?

    let hostName: String
    let onOpenDashboard: () -> Void

    @Published private(set) var pairedDevices: [PairedDevice] = []
    @Published private(set) var isAccessibilityGranted = AccessibilityPermission.isGranted

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

    init(config: Configuration?, updateManager: UpdateManager?, deviceDataSource: DeviceDataSource?, onOpenDashboard: @escaping () -> Void) {
        self.config = config
        self.updateManager = updateManager
        self.deviceDataSource = deviceDataSource
        self.hostName = config?.hostDeviceName ?? Host.current().localizedName ?? "This Mac"
        self.onOpenDashboard = onOpenDashboard
        self.launchAtLogin = config?.launchOnLogin ?? false
        self.checksForUpdatesAutomatically = updateManager?.automaticallyChecksForUpdates ?? false
        refreshDevices()
    }

    /// Re-reads values that can change while the window is closed or in the background
    func reload() {
        launchAtLogin = config?.launchOnLogin ?? false
        checksForUpdatesAutomatically = updateManager?.automaticallyChecksForUpdates ?? false
        isAccessibilityGranted = AccessibilityPermission.isGranted
        refreshDevices()
    }

    func refreshDevices() {
        guard let dataSource = deviceDataSource else { return }
        let reachable = Set(dataSource.pairedRechableDevices.map(\.id))
        pairedDevices = (dataSource.pairedDevices + dataSource.unavailableDevices)
            .map { device in
                PairedDevice(
                    id: device.id,
                    name: device.name,
                    isConnected: reachable.contains(device.id),
                    supportsEdgeControl: RemoteControlService.supportsEdgeControl(device)
                )
            }
            .sorted { $0.name < $1.name }
    }

    func checkForUpdates() {
        updateManager?.checkForUpdates()
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @ObservedObject var model: SettingsModel

    @AppStorage(AppDefaultsStore.Preferences.deviceTypeKey) private var deviceType = 0
    @AppStorage(AppDefaultsStore.Preferences.disableSharePopUpKey) private var sendToOnlyDevice = false
    @AppStorage(AppDefaultsStore.Preferences.Bluetooth.enabledKey) private var bluetoothEnabled = false

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
                Text("Your devices see this name and icon. The name is this Mac’s name in General › About; changes reach devices the next time they connect.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Open at Login", isOn: $model.launchAtLogin)
                Toggle(isOn: $sendToOnlyDevice) {
                    Text("Send Dropped Items Without Asking")
                    Text("When only one device is connected, items dropped on the menu bar icon go straight to it.")
                }
            }

            Section {
                Toggle(isOn: $bluetoothEnabled) {
                    Text("Connect over Bluetooth")
                    Text("Also reach phones over Bluetooth, for when they aren’t on the same network. Pair the phone with this Mac in System Settings › Bluetooth and turn on Bluetooth in KDE Connect’s settings on the phone. File transfers go over the network when it’s available.")
                }
            }
            
            Section {
                LabeledContent {
                    Button("Open Dashboard", action: model.onOpenDashboard)
                } label: {
                    Text("Devices")
                    Text("Pair, unpair and reconnect devices in the Dashboard.")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 480)
    }
}

// MARK: - Menu Bar

struct MenuBarSettingsView: View {
    @AppStorage(AppDefaultsStore.Preferences.MenuBar.showDeviceIconKey) private var showDeviceIcon = false
    @AppStorage(AppDefaultsStore.Preferences.MenuBar.showBatteryKey) private var showBattery = false
    @AppStorage(AppDefaultsStore.Preferences.MenuBar.showSignalKey) private var showSignal = false

    var body: some View {
        Form {
            Section {
                Toggle("Device Icon", isOn: $showDeviceIcon)
                Toggle("Battery Level", isOn: $showBattery)
                Toggle("Signal Strength", isOn: $showSignal)
            } header: {
                Text("Show in Menu Bar")
            } footer: {
                Text("Shown while exactly one device is connected. With no device or several, the menu bar shows the Soduto icon.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 260)
    }
}

// MARK: - Control

struct ControlSettingsView: View {
    @ObservedObject var model: SettingsModel

    @AppStorage(AppDefaultsStore.Preferences.EdgeControl.enabledKey) private var edgeControlEnabled = false
    @AppStorage(AppDefaultsStore.Preferences.EdgeControl.edgeKey) private var edge = ScreenEdge.right.rawValue
    @AppStorage(AppDefaultsStore.Preferences.EdgeControl.deviceIdKey) private var deviceId = ""
    @AppStorage(AppDefaultsStore.Preferences.Control.suppressInterferenceWarningKey) private var suppressInterferenceWarning = false

    @State private var showingEdgeIntro = false

    private var selectedEdge: ScreenEdge { ScreenEdge(rawValue: edge) ?? .right }

    private var targetName: String {
        if let device = model.pairedDevices.first(where: { $0.id == deviceId }) { return device.name }
        let capable = model.pairedDevices.filter { $0.isConnected && $0.supportsEdgeControl }
        return capable.count == 1 ? capable[0].name : "your device"
    }

    /// A problem worth telling the user about, if any
    private var edgeControlIssue: String? {
        guard edgeControlEnabled else { return nil }
        if !model.isAccessibilityGranted {
            return "Soduto needs Accessibility access to control a device (see below)."
        }
        if let device = model.pairedDevices.first(where: { $0.id == deviceId }) {
            if device.isConnected && !device.supportsEdgeControl {
                return "Turn on “Input devices receiver” for this Mac in KDE Connect on \(device.name)."
            }
            return nil
        }
        let capable = model.pairedDevices.filter { $0.isConnected && $0.supportsEdgeControl }
        if capable.count > 1 {
            return "Several connected devices support this; choose one above."
        }
        return nil
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $edgeControlEnabled) {
                    Text("Control a Device from the Screen Edge")
                    Text("Push the pointer past an edge of the screen to use this Mac’s keyboard and mouse on the device; move it back to return.")
                }
                .onChange(of: edgeControlEnabled) { _, isOn in
                    if isOn { showingEdgeIntro = true }
                }

                Picker("Device", selection: $deviceId) {
                    Text("Automatic").tag("")
                    ForEach(model.pairedDevices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .disabled(!edgeControlEnabled)

                Picker("Device Is On This Side", selection: $edge) {
                    ForEach(ScreenEdge.allCases) { edge in
                        Text(edge.title).tag(edge.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!edgeControlEnabled)
            } header: {
                Text("Screen Edge")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if let issue = edgeControlIssue {
                        Label(issue, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    Text("Uses the edge of the display with the menu bar. Needs KDE Connect’s “Input devices receiver” on the device; Automatic picks the only connected device that has it.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                LabeledContent("Stop Controlling", value: "⌥⎋  Option-Escape")
                Toggle(isOn: Binding(get: { !suppressInterferenceWarning }, set: { suppressInterferenceWarning = !$0 })) {
                    Text("Explain When Another App Acts on This Mac")
                    Text("After a session in which something like a mouse utility opened Mission Control, show which utilities are running and how to keep them off.")
                }
                LabeledContent {
                    if model.isAccessibilityGranted {
                        Label("Allowed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Open System Settings") { AccessibilityPermission.openSettings() }
                    }
                } label: {
                    Text("Accessibility")
                    Text(AccessibilityPermission.settingsLocation)
                }
            } footer: {
                Text("Works the same for Control Device in a device’s menu and for the screen edge.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 500)
        .alert("Screen Edge Control Is On", isPresented: $showingEdgeIntro) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Push the pointer past the \(selectedEdge.title.lowercased()) edge of the screen to control \(targetName). To come back, move its pointer back out through the same edge.\n\nIf the pointer ever gets stuck on the device, press Option-Escape (⌥⎋) to take back your keyboard and mouse.")
        }
    }
}

// MARK: - Updates

struct UpdatesSettingsView: View {
    @ObservedObject var model: SettingsModel

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: version)
                Toggle("Check for Updates Automatically", isOn: $model.checksForUpdatesAutomatically)
                LabeledContent {
                    Button("Check Now", action: model.checkForUpdates)
                } label: {
                    Text("Check for Updates")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 220)
    }
}
