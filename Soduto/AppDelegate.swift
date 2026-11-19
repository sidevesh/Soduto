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
        let notificationName = AppDefaultsStore.DarwinNotifications.shareHandoff as CFString
        let notificationCenter = CFNotificationCenterGetDarwinNotifyCenter()
        registerShareExtensionObserver(notificationCenter, notificationName)
        
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wakeUpListener(_:)), name: NSWorkspace.didWakeNotification, object: nil)
        observeLifecycleForDiagnostics()
        
        self.connectionProvider.start()
        self.updateBluetooth()
        self.bluetoothDefaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.updateBluetooth()
        }
        
        showWelcomeWindow()
    }
    
    func applicationWillTerminate(_ aNotification: Notification) {
        Logger.general.notice("Soduto is quitting normally")
        UserDefaults.standard.removeObject(forKey: Self.lastAliveKey)
        heartbeatTimer?.invalidate()
        AppDefaultsStore.ShareExtension.appLastHeartbeat = 0
        AppDefaultsStore.ShareExtension.reachableDevices = []
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
        AppDefaultsStore.ShareExtension.appLastHeartbeat = Date().timeIntervalSince1970
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastAliveKey)
        Self.logMemoryFootprint("at launch")
        var ticks = 0
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            AppDefaultsStore.ShareExtension.appLastHeartbeat = Date().timeIntervalSince1970
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
        let deviceEntries: [[String: String]] = self.validDevices.map { [
            "id": $0.id,
            "name": $0.name,
            "type": $0.type.rawValue
        ] }
        AppDefaultsStore.ShareExtension.reachableDevices = deviceEntries
    }
    
    static func shared() -> AppDelegate {
        guard let delegate = NSApplication.shared.delegate as? AppDelegate else { fatalError("AppDelegate not configured") }
        return delegate
    }
    
    /// Darwin Notification Center Observer to observe notifications from Share Extension
    fileprivate func registerShareExtensionObserver(_ notificationCenter: CFNotificationCenter?, _ notificationName: CFString) {
        CFNotificationCenterAddObserver(notificationCenter, nil, { _, _, _, _, _ in
            AppDelegate.shared().handleShareExtensionTrigger()
        }, notificationName, nil, .deliverImmediately)
    }
    
    private func handleShareExtensionTrigger() {
        guard let deviceId = AppDefaultsStore.ShareExtension.selectedDevice, !deviceId.isEmpty else {
            UserNotificationHelper.show(title: "Soduto Share", body: "No target device was specified. Please try sharing again.", sound: true, id: "NoDeviceSelected")
            return
        }
        
        let bookmarks = AppDefaultsStore.ShareExtension.fileBookmarkData ?? []
        let texts = AppDefaultsStore.ShareExtension.sharedTexts ?? []
        
        guard !bookmarks.isEmpty || !texts.isEmpty else {
            ShareService.reportExtensionTransferStatus(deviceId: deviceId, status: "failed")
            UserNotificationHelper.show(title: "Soduto Share", body: "Nothing to share. Please try again.", sound: true, id: "NoShareData")
            return
        }
        
        guard let shareService = self.serviceManager.service(ofType: ShareService.self) else {
            ShareService.reportExtensionTransferStatus(deviceId: deviceId, status: "failed")
            UserNotificationHelper.show(title: "Soduto Share", body: "Share service is not available. Please restart Soduto.", sound: true, id: "ShareServiceUnavailable")
            return
        }
        
        guard let device = self.deviceManager.device(withId: deviceId) else {
            ShareService.reportExtensionTransferStatus(deviceId: deviceId, status: "failed")
            UserNotificationHelper.show(title: "Soduto Share", body: "The selected device is no longer reachable.", sound: true, id: "DeviceUnreachable")
            return
        }
        
        // Pass 1: resolve all bookmarks into URLs without sending yet
        // This lets us pre-count file uploads and register the batch BEFORE sending,
        // so each packet can be stamped with `numberOfFiles` (protocol requirement)
        var resolvedUrls: [URL] = []
        var failedCount = 0
        for data in bookmarks {
            do {
                var isStale = false
                let url = try URL(resolvingBookmarkData: data, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &isStale)
                resolvedUrls.append(url)
            } catch {
                failedCount += 1
                Logger.general.error("Failed to resolve bookmark: \(error, privacy: .public)")
            }
        }
        
        // Pre-count valid file uploads (non-directory file: URLs that ShareService will queue)
        let fileUrls = resolvedUrls.filter { url -> Bool in
            var isDirectory: ObjCBool = false
            return url.isFileURL
                && FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
        }
        let estimatedTotalBytes = fileUrls.reduce(Int64(0)) { sum, url in
            sum + ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0)
        }
        
        // Register batch BEFORE sending so shareFromExtension can stamp numberOfFiles on packets
        //
        // Pre-count vs actual-queue mismatch: our filter (fileExists + !isDirectory) mirrors the
        // checks inside dataPacket(forFileUrl:), with one exception: InputStream(url:) could
        // theoretically return nil for a file that exists. If that happened, the batch would be
        // registered for N but only (N - 1) packets sent, leaving isDone unreachable
        // In practice this is not a real risk: the Share extension uses Security-scoped bookmarks,
        // and a successful bookmark resolution guarantees OS-level read access, so InputStream
        // creation will always succeed for any URL that passes our filter
        if !fileUrls.isEmpty {
            shareService.beginTrackingExtensionUploads(deviceId: deviceId, fileCount: fileUrls.count, totalBytes: estimatedTotalBytes)
        }
        
        if failedCount > 0 {
            let message = failedCount == bookmarks.count
                ? "Soduto Share doesn't have permissions to read files in this directory. Drag the file to the menu bar icon to share!"
                : "\(failedCount) of \(bookmarks.count) items could not be shared."
            UserNotificationHelper.show(title: "Soduto Share", subtitle: "Oops! We got lost!", body: message, sound: true, id: "FileAccessDenied")
        }
        
        // Pass 2: send all resolved URLs
        var fileUploadCount = 0
        for url in resolvedUrls {
            switch shareService.shareFromExtension(url: url, to: device) {
            case .fileUploadQueued:    fileUploadCount += 1
            case .sentWithoutPayload:  break
            case .skipped:             failedCount += 1
            }
        }
        
        // Process shared texts
        for text in texts {
            shareService.shareFromExtension(text: text, to: device)
        }
        
        // File uploads are tracked by ShareService,it reports the real completion status via
        // Darwin notification when all uploads finish. Non-file transfers complete immediately
        if fileUploadCount == 0 {
            if failedCount == bookmarks.count && !bookmarks.isEmpty && texts.isEmpty {
                // Everything failed, nothing was sent
                ShareService.reportExtensionTransferStatus(deviceId: deviceId, status: "failed")
            } else {
                // Only URLs/texts were shared (no file payloads) — they complete immediately
                ShareService.reportExtensionTransferStatus(deviceId: deviceId, status: "success")
            }
        }
        
        // Clear consumed data (NOT transferStatuses, extension needs them)
        // Each device reads only its own transferStatus entry by ID & old entries are inert and cleared on extension deinit
        AppDefaultsStore.ShareExtension.fileBookmarkData = nil
        AppDefaultsStore.ShareExtension.sharedTexts = nil
        AppDefaultsStore.ShareExtension.selectedDevice = nil
    }
}
