//
//  SharedUserDefaults.swift
//  Soduto
//
//  Created by Sannidhya Roy on 04/12/22.
//  Copyright © 2022 Soduto. All rights reserved.
//

import AppKit

enum AppDefaultsStore {
    // MARK: - Bundle Identity
    
    // Extension bundle identifiers must use the main app's bundle identifier as a prefix
    // (e.g. "com.example.App.Share"). The last dot-component is stripped when running inside
    // an extension (.appex) to recover the host app's identifier.
    static let mainBundleId: String = {
        var id = Bundle.main.bundleIdentifier!
        if Bundle.main.bundleURL.pathExtension == "appex" {
            id = id.components(separatedBy: ".").dropLast().joined(separator: ".")
        }
        return id
    }()
    
    // Reverse-DNS domain prefix (everything before the final app-name component).
    // e.g. "com.example.App" → "com.example". Used as the root namespace for all stored keys
    // so that forks with different bundle IDs get their own isolated key space automatically.
    fileprivate static let base: String = mainBundleId.components(separatedBy: ".").dropLast().joined(separator: ".")
    
    // MARK: - Darwin Notification Names (cross-process pings: main app ↔ Share Extension)
    
    enum DarwinNotifications {
        /// Extension → app: publish the device list now
        static let shareRequestDevices = mainBundleId + ".share.requestDevices"
        /// App → extension: transfer statuses changed (see `ShareBridge.readStatuses`)
        static let shareStatus  = mainBundleId + ".share.status"
    }
    
    // MARK: - Share Extension Bridge
    
    /// How Soduto Share talks to the app without an App Group (which needs an Apple Developer Team ID,
    /// so self-signed builds can't use one):
    /// - the app keeps the reachable devices on a named pasteboard, and transfer statuses on another;
    ///   Darwin notifications say when to look
    /// - the extension sends its request (target device, shared text) as a `soduto-share:` link opened in
    ///   the app, then opens the shared files with the app through Launch Services, which gives the app
    ///   access to exactly those files, wherever they are
    enum ShareBridge {
        static let urlScheme = "soduto-share"
        
        struct DeviceEntry: Codable, Hashable {
            let id: String
            let name: String
            let type: String
        }
        
        private struct DeviceList: Codable {
            let updated: TimeInterval
            let devices: [DeviceEntry]
        }
        
        private static let devicesPasteboard = NSPasteboard.Name(mainBundleId + ".share.devices")
        private static let statusPasteboard = NSPasteboard.Name(mainBundleId + ".share.status")
        private static let dataType = NSPasteboard.PasteboardType(mainBundleId + ".share.data")
        
        // MARK: Devices
        
        /// App: the devices the extension may offer (also refreshed periodically as a heartbeat)
        static func publish(devices: [DeviceEntry]) {
            write(DeviceList(updated: Date().timeIntervalSince1970, devices: devices), to: devicesPasteboard)
        }
        
        /// Extension: the published devices, or nil when the app hasn't published recently (not running)
        static func readDevices(maxAge: TimeInterval = 90) -> [DeviceEntry]? {
            guard let list: DeviceList = read(from: devicesPasteboard),
                  Date().timeIntervalSince1970 - list.updated < maxAge else { return nil }
            return list.devices
        }
        
        // MARK: Statuses
        
        /// App: "success" or "failed" for a device the extension sent to
        static func publish(status: String, forDevice deviceId: String) {
            var statuses = readStatuses()
            statuses[deviceId] = status
            write(statuses, to: statusPasteboard)
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                                 CFNotificationName(DarwinNotifications.shareStatus as CFString), nil, nil, true)
        }
        
        static func readStatuses() -> [String: String] {
            read(from: statusPasteboard) ?? [:]
        }
        
        /// Extension: forget the previous status for a device before sending to it again
        static func clearStatus(forDevice deviceId: String) {
            var statuses = readStatuses()
            guard statuses.removeValue(forKey: deviceId) != nil else { return }
            write(statuses, to: statusPasteboard)
        }
        
        // MARK: Requests
        
        struct Request {
            let deviceId: String
            /// Files that follow in a separate open
            let fileCount: Int
            let texts: [String]
        }
        
        static func url(for request: Request) -> URL? {
            var components = URLComponents()
            components.scheme = urlScheme
            components.host = "send"
            components.queryItems = [
                URLQueryItem(name: "device", value: request.deviceId),
                URLQueryItem(name: "files", value: String(request.fileCount)),
            ] + request.texts.map { URLQueryItem(name: "text", value: $0) }
            return components.url
        }
        
        static func request(from url: URL) -> Request? {
            guard url.scheme == urlScheme, url.host == "send",
                  let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                  let deviceId = items.first(where: { $0.name == "device" })?.value else { return nil }
            let fileCount = items.first(where: { $0.name == "files" })?.value.flatMap(Int.init) ?? 0
            let texts = items.filter { $0.name == "text" }.compactMap(\.value)
            return Request(deviceId: deviceId, fileCount: fileCount, texts: texts)
        }
        
        // MARK: Pasteboard storage
        
        private static func write<T: Encodable>(_ value: T, to name: NSPasteboard.Name) {
            guard let data = try? JSONEncoder().encode(value) else { return }
            let pasteboard = NSPasteboard(name: name)
            pasteboard.clearContents()
            pasteboard.setData(data, forType: dataType)
        }
        
        private static func read<T: Decodable>(from name: NSPasteboard.Name) -> T? {
            guard let data = NSPasteboard(name: name).data(forType: dataType) else { return nil }
            return try? JSONDecoder().decode(T.self, from: data)
        }
    }
    
    
    // MARK: - User Preferences
    
    enum Preferences {
        fileprivate static let base = "\(AppDefaultsStore.base).preferences"
        
        static let disableSharePopUpKey = "\(base).disablesharepopup"
        static var disableSharePopUp: Bool {
            get { UserDefaults.standard.bool(forKey: disableSharePopUpKey) }
            set { UserDefaults.standard.set(newValue, forKey: disableSharePopUpKey) }
        }
        
        static let deviceTypeKey = "\(base).devicetype"
        static var deviceType: Int {
            get { UserDefaults.standard.integer(forKey: deviceTypeKey) }
            set { UserDefaults.standard.set(newValue, forKey: deviceTypeKey) }
        }
        
        // MARK: Edge Control
        
        /// Hand the keyboard and mouse to a device by pushing the pointer past an edge of the main display
        enum EdgeControl {
            fileprivate static let base = "\(Preferences.base).edgecontrol"
            static let enabledKey = "\(base).enabled"
            /// `ScreenEdge.rawValue`; defaults to "right"
            static let edgeKey = "\(base).edge"
            /// Paired device to control; empty means "the connected device that supports it"
            static let deviceIdKey = "\(base).deviceId"
            
            static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
            static var edge: String { UserDefaults.standard.string(forKey: edgeKey) ?? "right" }
            static var deviceId: String { UserDefaults.standard.string(forKey: deviceIdKey) ?? "" }
        }
        
        // MARK: Bluetooth
        
        /// Connect to devices over Bluetooth as well as the network (off by default)
        enum Bluetooth {
            fileprivate static let base = "\(Preferences.base).bluetooth"
            static let enabledKey = "\(base).enabled"
            
            static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
        }
        
        // MARK: Calls
        
        /// Taking the phone's calls on this Mac over Bluetooth Hands-Free
        enum Calls {
            fileprivate static let base = "\(Preferences.base).calls"
            static let enabledKey = "\(base).enabled"
            /// Bluetooth address of the phone; empty means "the only paired phone"
            static let phoneAddressKey = "\(base).phoneAddress"
            static let silentKey = "\(base).silent"
            
            static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
            static var phoneAddress: String { UserDefaults.standard.string(forKey: phoneAddressKey) ?? "" }
            static var ringsOnMac: Bool { !UserDefaults.standard.bool(forKey: silentKey) }
        }
        
        // MARK: Control
        
        enum Control {
            fileprivate static let base = "\(Preferences.base).control"
            /// Set from the "Don't show again" box of the alert that explains other apps acting on the
            /// Mac during a control session; off by default (warn)
            static let suppressInterferenceWarningKey = "\(base).suppressInterferenceWarning"
            
            static var suppressInterferenceWarning: Bool {
                get { UserDefaults.standard.bool(forKey: suppressInterferenceWarningKey) }
                set { UserDefaults.standard.set(newValue, forKey: suppressInterferenceWarningKey) }
            }
        }
        
        // MARK: Menu Bar
        
        /// What the menu bar icon shows while exactly one device is connected (otherwise the Soduto icon)
        enum MenuBar {
            fileprivate static let base = "\(Preferences.base).menubar"
            static let showDeviceIconKey = "\(base).showDeviceIcon"
            static let showBatteryKey = "\(base).showBattery"
            static let showSignalKey = "\(base).showSignal"
            
            static var showDeviceIcon: Bool { UserDefaults.standard.bool(forKey: showDeviceIconKey) }
            static var showBattery: Bool { UserDefaults.standard.bool(forKey: showBatteryKey) }
            static var showSignal: Bool { UserDefaults.standard.bool(forKey: showSignalKey) }
            static var showsDeviceStatus: Bool { showDeviceIcon || showBattery || showSignal }
        }
        
        // MARK: Service Enable/Disable
        
        enum Services {
            fileprivate static let base = "\(Preferences.base).services"
            
            enum Battery: ServiceToggle {
                static let base = "\(Services.base).battery"
            }
            
            enum Clipboard: ServiceToggle {
                static let base = "\(Services.base).clipboard"
            }
            
            enum Contacts: ServiceIncomingToggle {
                static let base = "\(Services.base).contacts"
            }
            
            enum Digitizer: ServiceIncomingToggle {
                static let base = "\(Services.base).digitizer"
            }
            
            enum FindMy: ServiceToggle {
                static let base = "\(Services.base).findmy"
            }
            
            /// Media sync (MPRIS): incoming = remote players on the Mac, outgoing = Mac player on the remote device
            enum MediaPlayer: ServiceToggle {
                static let base = "\(Services.base).mpris"
            }
            
            enum MousePad: ServiceIncomingToggle {
                static let base = "\(Services.base).mousepad"
            }
            
            enum Presenter: ServiceIncomingToggle {
                static let base = "\(Services.base).presenter"
            }
            
            enum RemoteControl: ServiceOutgoingToggle {
                static let base = "\(Services.base).remotecontrol"
            }
            
            enum RunCommand: ServiceToggle {
                static let base = "\(Services.base).runcommand"
                static let commandsKey = "\(base).commands"
            }
            
            enum SMS: ServiceIncomingToggle {
                static let base = "\(Services.base).sms"
            }
            
            enum SystemVolume: ServiceOutgoingToggle {
                static let base = "\(Services.base).systemvolume"
            }
        }
    }
}


// MARK: - Service Preference Helpers

/// A service that can receive data from a remote device (incoming direction)
protocol ServiceIncomingToggle {
    /// Namespace prefix for this service, e.g. "com.soduto.preferences.services.clipboard"
    static var base: String { get }
}
extension ServiceIncomingToggle {
    static var incomingKey: String { "\(base).incoming" }
    static var incomingEnabled: Bool {
        get { UserDefaults.standard.serviceBool(incomingKey) }
        set { UserDefaults.standard.set(newValue, forKey: incomingKey) }
    }
}

/// A service that can send data to a remote device (outgoing direction)
protocol ServiceOutgoingToggle {
    /// Namespace prefix for this service, e.g. "com.soduto.preferences.services.clipboard"
    static var base: String { get }
}
extension ServiceOutgoingToggle {
    static var outgoingKey: String { "\(base).outgoing" }
    static var outgoingEnabled: Bool {
        get { UserDefaults.standard.serviceBool(outgoingKey) }
        set { UserDefaults.standard.set(newValue, forKey: outgoingKey) }
    }
}

/// Convenience alias for services with both directions
typealias ServiceToggle = ServiceIncomingToggle & ServiceOutgoingToggle

extension UserDefaults {
    /// Reads a Bool preference that defaults to `true` when not yet set
    func serviceBool(_ key: String) -> Bool { object(forKey: key) as? Bool ?? true }
}
