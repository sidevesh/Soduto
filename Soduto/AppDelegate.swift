//
//  AppDelegate.swift
//  Soduto
//
//  Created by Giedrius Stanevičius on 2016-07-06.
//  Copyright © 2016 Soduto. All rights reserved.
//

import Cocoa
import Foundation
import os
import UserNotifications
import Sparkle
import MediaPlayer

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate, DeviceManagerDelegate {
    
    var validDevices: [Device] = []
    @IBOutlet weak var statusBarMenuController: StatusBarMenuController!
    @IBOutlet weak var checkForUpdatesMenuItem: NSMenuItem!
    var welcomeWindowController: WelcomeWindowController?
    
    let config = Configuration()
    let connectionProvider: ConnectionProvider
    let bluetoothLinkProvider: BluetoothLinkProvider
    private var isBluetoothRunning = false
    private var bluetoothDefaultsObserver: NSObjectProtocol?
    let deviceManager: DeviceManager
    let serviceManager = ServiceManager()
    private(set) var userNotificationManager: UserNotificationManager!
    let updateManager: UpdateManager
    private var heartbeatTimer: Timer?
    /// The previous run's last heartbeat, if it never reached `applicationWillTerminate`
    private var previousLastAlive: TimeInterval?
    
    override init() {
        self.connectionProvider = ConnectionProvider(config: config)
        self.bluetoothLinkProvider = BluetoothLinkProvider(config: config)
        self.deviceManager = DeviceManager(config: config, serviceManager: self.serviceManager)
        self.updateManager = UpdateManager()
        
        super.init()
        
        self.checkOneAppInstanceRunning()
    }
    
    
    // MARK: NSApplicationDelegate
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Keep nothing in Library/Caches: macOS's cache cleaner quits sandboxed apps to purge it
        FileManager.default.clearPurgeableCaches()
        URLCache.shared = URLCache(memoryCapacity: 8 * 1024 * 1024, diskCapacity: 0)
        
        self.userNotificationManager = UserNotificationManager(config: self.config, serviceManager: self.serviceManager, deviceManager: self.deviceManager)
        self.config.capabilitiesDataSource = self.serviceManager
        self.connectionProvider.delegate = self.deviceManager
        self.bluetoothLinkProvider.delegate = self.deviceManager
        self.statusBarMenuController.deviceDataSource = self.deviceManager
        self.statusBarMenuController.serviceManager = self.serviceManager
        self.statusBarMenuController.config = self.config
        self.deviceManager.delegate = self
        
        self.checkForUpdatesMenuItem.target = updateManager.updaterController
        self.checkForUpdatesMenuItem.action = #selector(SPUStandardUpdaterController.checkForUpdates(_:))
        
        self.serviceManager.add(service: NotificationsService())
        self.serviceManager.add(service: ClipboardService())
        self.serviceManager.add(service: SftpService())
        self.serviceManager.add(service: ShareService())
        self.serviceManager.add(service: TelephonyService())
        self.serviceManager.add(service: ContactsService())
        self.serviceManager.add(service: SMSService())
        self.serviceManager.add(service: PingService())
        self.serviceManager.add(service: BatteryService())
        self.serviceManager.add(service: SystemVolumeService())
        self.serviceManager.add(service: ConnectivityReportService())
        self.serviceManager.add(service: FindMyService())
        self.serviceManager.add(service: PresenterService())
        self.serviceManager.add(service: RemoteInputService())
        self.serviceManager.add(service: DigitizerService())
        self.serviceManager.add(service: RemoteControlService())
        self.serviceManager.add(service: RunCommandService())
        self.serviceManager.add(service: MediaPlayerService())
        self.statusBarMenuController.startServiceObservers()
        
        self.updateValidDevices()
        self.startHeartbeat()
        registerShareExtensionObserver()
        
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wakeUpListener(_:)), name: NSWorkspace.didWakeNotification, object: nil)
        observeLifecycleForDiagnostics()
        
        self.connectionProvider.start()
        self.updateBluetooth()
        CallManager.shared.activate()
        self.bluetoothDefaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.updateBluetooth()
        }
        
        showWelcomeWindow()
    }
    
    func applicationWillTerminate(_ aNotification: Notification) {
        Logger.general.notice("Soduto is quitting normally")
        UserDefaults.standard.removeObject(forKey: Self.lastAliveKey)
        heartbeatTimer?.invalidate()
        AppDefaultsStore.ShareBridge.publish(devices: [])
    }
    
    
    // MARK: DeviceManagerDelegate
    
    func deviceManager(_ manager: DeviceManager, didChangeDeviceState device: Device) {
        self.statusBarMenuController.refreshDeviceLists()
        self.welcomeWindowController?.refreshDeviceLists()
        self.updateValidDevices()
    }
    
    func deviceManager(_ manager: DeviceManager, didReceivePairingRequest request: PairingRequest, forDevice device: Device) {
        Logger.general.debug("deviceManager(<\(String(describing: request), privacy: .public)> didReceivePairingRequest:<\(String(describing: request), privacy: .public)> forDevice:<\(String(describing: device), privacy: .public)>)")
        PairingInterfaceController.showPairingWindow(for: device)
    }
    
    
    // MARK: Private
    
    private func checkOneAppInstanceRunning() {
        let lockFileName = FileManager.default.temporaryDirectory.appendingPathComponent(self.config.hostDeviceId).appendingPathExtension("lock").path
        if !tryLock(lockFileName) {
            let alert = NSAlert()
            alert.addButton(withTitle: "Quit Soduto")
            alert.informativeText = NSLocalizedString("Another instance of the app is already running!", comment: "")
            alert.messageText = Bundle.main.bundleIdentifier?.components(separatedBy: ".").last ?? ""
            alert.runModal()
            NSApp.terminate(self)
        }
    }
    
    private func showWelcomeWindow() {
        guard self.config.knownDeviceConfigs().filter({ $0.isPaired }).isEmpty else { return }
        
        let storyboard = NSStoryboard(name: "WelcomeWindow", bundle: nil)
        guard let controller = storyboard.instantiateInitialController() as? WelcomeWindowController else { assertionFailure("Could not load welcome window controller."); return }
        
        NSApp.activate(ignoringOtherApps: true)
        
        controller.deviceDataSource = self.deviceManager
        controller.dismissHandler = { [weak self] _ in self?.welcomeWindowController = nil }
        controller.showWindow(nil)
        self.welcomeWindowController = controller
    }
    
    // MARK: WakeUP Function
    
    @objc private func wakeUpListener(_ aNotification: Notification) {
        Logger.general.notice("Mac woke from sleep; restarting network services")
        self.connectionProvider.restart()
        self.bluetoothLinkProvider.restart()
        self.updateValidDevices()
    }
    
    // MARK: Bluetooth
    
    /// Connect over Bluetooth while it's turned on in Settings › General
    private func updateBluetooth() {
        let enabled = AppDefaultsStore.Preferences.Bluetooth.isEnabled
        guard enabled != isBluetoothRunning else { return }
        isBluetoothRunning = enabled
        if enabled {
            self.bluetoothLinkProvider.start()
        } else {
            self.bluetoothLinkProvider.stop()
        }
    }
    
    // MARK: Extension Support
    
    private func startHeartbeat() {
        let lastAlive = UserDefaults.standard.double(forKey: Self.lastAliveKey)
        previousLastAlive = lastAlive > 0 ? lastAlive : nil
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastAliveKey)
        Self.logMemoryFootprint("at launch")
        var ticks = 0
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            // Republish so Soduto Share knows the app is running
            AppDelegate.shared().updateValidDevices()
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastAliveKey)
            ticks += 1
            if ticks % 20 == 0 { Self.logMemoryFootprint("periodic") }  // every 10 minutes
        }
    }
    
    /// Logs the memory macOS charges Soduto for (what memory-pressure kills go by), to spot growth
    private static func logMemoryFootprint(_ when: String) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }
        let megabytes = Double(info.phys_footprint) / 1_048_576
        Logger.general.notice("Memory footprint (\(when, privacy: .public)): \(String(format: "%.1f", megabytes), privacy: .public) MB")
    }
    
    // MARK: Diagnostics
    
    /// Last time this run was known to be alive (every 30 s); removed on a normal quit
    private static let lastAliveKey = "\(AppDefaultsStore.mainBundleId).diagnostics.lastAlive"
    
    /// Leaves markers in the system log (`log show --predicate 'subsystem == "com.soduto.Soduto"'`) for
    /// sleep, wake, screen lock and unlock, and notes when the previous run ended without quitting, so a
    /// vanished menu bar icon can be matched to what the Mac was doing at the time.
    private func observeLifecycleForDiagnostics() {
        // startHeartbeat() (which runs first) kept the value it replaced
        if let previous = previousLastAlive {
            let date = Date(timeIntervalSince1970: previous)
            Logger.general.error("Previous Soduto run ended unexpectedly (crash or forced quit); last alive \(date, privacy: .public)")
        }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            Logger.general.notice("Mac is going to sleep")
        }
        workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { _ in
            Logger.general.notice("Displays went to sleep")
            Self.logMemoryFootprint("displays asleep")
        }
        workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in
            Logger.general.notice("Displays woke")
        }
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            Logger.general.notice("Screen locked")
        }
        distributed.addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            Logger.general.notice("Screen unlocked")
        }
    }
    
    public func updateValidDevices() {
        self.validDevices = deviceManager.pairedRechableDevices
        AppDefaultsStore.ShareBridge.publish(devices: self.validDevices.map {
            .init(id: $0.id, name: $0.name, type: $0.type.rawValue)
        })
    }
    
    static func shared() -> AppDelegate {
        guard let delegate = NSApplication.shared.delegate as? AppDelegate else { fatalError("AppDelegate not configured") }
        return delegate
    }
    
    /// Soduto Share asks for the device list with a Darwin notification
    fileprivate func registerShareExtensionObserver() {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
            DispatchQueue.main.async { AppDelegate.shared().updateValidDevices() }
        }, AppDefaultsStore.DarwinNotifications.shareRequestDevices as CFString, nil, .deliverImmediately)
    }
    
    // MARK: Opening (Soduto Share, Open With)
    
    /// A Soduto Share request waiting for its files, which arrive in a separate open
    private struct PendingShare {
        let deviceId: Device.Id
        var remainingFiles: Int
        let date: Date
    }
    private var pendingShare: PendingShare?
    
    func application(_ application: NSApplication, open urls: [URL]) {
        var files: [URL] = []
        for url in urls {
            if let request = AppDefaultsStore.ShareBridge.request(from: url) {
                handleShareRequest(request)
            } else if url.isFileURL {
                files.append(url)
            }
        }
        guard !files.isEmpty else { return }
        
        if let pending = self.pendingShare, Date().timeIntervalSince(pending.date) < 60 {
            self.pendingShare = nil
            share(files: files, toDeviceWithId: pending.deviceId)
        } else if validDevices.count == 1, let device = validDevices.first {
            // Opened with Soduto from Finder ("Open With"): the only device it can go to
            share(files: files, toDeviceWithId: device.id)
        } else {
            UserNotificationHelper.show(title: "Soduto", body: validDevices.isEmpty ? "No device is connected to send the files to." : "Choose a device: share the files with Soduto Share, or drop them on Soduto’s menu bar icon.", sound: true, id: "ChooseShareDevice")
        }
    }
    
    /// A request from Soduto Share: send its texts now; its files (if any) follow in a separate open
    private func handleShareRequest(_ request: AppDefaultsStore.ShareBridge.Request) {
        guard let shareService = self.serviceManager.service(ofType: ShareService.self),
              let device = self.deviceManager.device(withId: request.deviceId) else {
            ShareService.reportExtensionTransferStatus(deviceId: request.deviceId, status: "failed")
            UserNotificationHelper.show(title: "Soduto Share", body: "The selected device is no longer reachable.", sound: true, id: "DeviceUnreachable")
            return
        }
        for text in request.texts {
            shareService.shareFromExtension(text: text, to: device)
        }
        if request.fileCount > 0 {
            self.pendingShare = PendingShare(deviceId: device.id, remainingFiles: request.fileCount, date: Date())
        } else {
            ShareService.reportExtensionTransferStatus(deviceId: device.id, status: "success")
        }
    }
    
    /// Sends files Soduto was given access to (by Soduto Share or Open With)
    private func share(files: [URL], toDeviceWithId deviceId: Device.Id) {
        guard let shareService = self.serviceManager.service(ofType: ShareService.self),
              let device = self.deviceManager.device(withId: deviceId) else {
            ShareService.reportExtensionTransferStatus(deviceId: deviceId, status: "failed")
            UserNotificationHelper.show(title: "Soduto Share", body: "The selected device is no longer reachable.", sound: true, id: "DeviceUnreachable")
            return
        }
        
        let fileUrls = files.filter { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }
        guard !fileUrls.isEmpty else {
            ShareService.reportExtensionTransferStatus(deviceId: deviceId, status: "failed")
            UserNotificationHelper.show(title: "Soduto Share", body: "Folders can’t be sent; choose files instead.", sound: true, id: "NoShareData")
            return
        }
        let totalBytes = fileUrls.reduce(Int64(0)) { sum, url in
            sum + ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0)
        }
        // Register the batch before sending, so each packet carries numberOfFiles (protocol requirement)
        shareService.beginTrackingExtensionUploads(deviceId: deviceId, fileCount: fileUrls.count, totalBytes: totalBytes)
        
        var queued = 0
        for url in fileUrls {
            if case .fileUploadQueued = shareService.shareFromExtension(url: url, to: device) {
                queued += 1
            }
        }
        // Uploads report their own completion; if none could start, say so now
        if queued == 0 {
            ShareService.reportExtensionTransferStatus(deviceId: deviceId, status: "failed")
        }
    }
}
