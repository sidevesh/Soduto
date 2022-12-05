//
//  AppDelegate.swift
//  Soduto
//
//  Created by Giedrius Stanevičius on 2016-07-06.
//  Copyright © 2016 Soduto. All rights reserved.
//

import Cocoa
import Foundation
import CleanroomLogger
import UserNotifications

let sharedUserDefaults = UserDefaults(suiteName: SharedUserDefaults.suiteName)

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate, DeviceManagerDelegate {
    
    let un = UNUserNotificationCenter.current()
    var validDevices: [Device] = []
    var validDeviceNames = [String]()
    @IBOutlet weak var statusBarMenuController: StatusBarMenuController!
    var welcomeWindowController: WelcomeWindowController?

    let config = Configuration()
    let connectionProvider: ConnectionProvider
    let deviceManager: DeviceManager
    let serviceManager = ServiceManager()
    let userNotificationManager: UserNotificationManager
    
    static let logLevelConfigurationKey = "com.soduto.logLevel"
    
    override init() {
        UserDefaults.standard.register(defaults: [AppDelegate.logLevelConfigurationKey: LogSeverity.info.rawValue])
        
        #if DEBUG
            Log.enable(configuration: XcodeLogConfiguration(minimumSeverity: .debug, debugMode: true))
        #else
            let formatter = FieldBasedLogFormatter(fields: [.severity(.simple), .delimiter(.spacedPipe), .payload])
            if let osRecorder = OSLogRecorder(formatters: [formatter]) {
                let severity: LogSeverity = LogSeverity(rawValue: UserDefaults.standard.integer(forKey: AppDelegate.logLevelConfigurationKey)) ?? .info
                Log.enable(configuration: BasicLogConfiguration(minimumSeverity: severity, recorders: [osRecorder]))
            }
        #endif
        
        
        self.connectionProvider = ConnectionProvider(config: config)
        self.deviceManager = DeviceManager(config: config, serviceManager: self.serviceManager)
        self.userNotificationManager = UserNotificationManager(config: self.config, serviceManager: self.serviceManager, deviceManager: self.deviceManager)
        
        super.init()
        
        self.checkOneAppInstanceRunning()
    }
    
    
    // MARK: NSApplicationDelegate
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        self.config.capabilitiesDataSource = self.serviceManager
        self.connectionProvider.delegate = self.deviceManager
        self.statusBarMenuController.deviceDataSource = self.deviceManager
        self.statusBarMenuController.serviceManager = self.serviceManager
        self.statusBarMenuController.config = self.config
        self.deviceManager.delegate = self
        
        self.serviceManager.add(service: NotificationsService())
        self.serviceManager.add(service: ClipboardService())
        self.serviceManager.add(service: SftpService())
        self.serviceManager.add(service: ShareService())
        self.serviceManager.add(service: TelephonyService())
        self.serviceManager.add(service: PingService())
        self.serviceManager.add(service: BatteryService())
        self.serviceManager.add(service: FindMyPhoneService())
//        self.serviceManager.add(service: RemoteKeyboardService())
        un.delegate = self
        self.updateValidDevices()
        let notificationName = "com.Soduto.Share" as CFString
        let notificationCenter = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(notificationCenter,
                                        nil,
                                        { (
                                            center: CFNotificationCenter?,
                                            observer: UnsafeMutableRawPointer?,
                                            name: CFNotificationName?,
                                            object: UnsafeRawPointer?,
                                            userInfo: CFDictionary?
                                        ) in
            
            guard let buttonTag = sharedUserDefaults?.integer(forKey: SharedUserDefaults.Keys.buttonTag) else { return }
            guard let url = sharedUserDefaults?.url(forKey: SharedUserDefaults.Keys.fileurl) else { return }
            ShareService().shareFile(url: url, to: buttonTag)
        },
                                        notificationName,
                                        nil,
                                        CFNotificationSuspensionBehavior.deliverImmediately)
        
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wakeUpListener(_:)), name: NSWorkspace.didWakeNotification, object: nil)
        
        self.connectionProvider.start()
        
        showWelcomeWindow()
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // Insert code here to tear down your application
    }

    
    // MARK: DeviceManagerDelegate
    
    func deviceManager(_ manager: DeviceManager, didChangeDeviceState device: Device) {
        self.statusBarMenuController.refreshDeviceLists()
        self.welcomeWindowController?.refreshDeviceLists()
        self.updateValidDevices()
    }
    
    func deviceManager(_ manager: DeviceManager, didReceivePairingRequest request: PairingRequest, forDevice device: Device) {
        Log.debug?.message("deviceManager(<\(request)> didReceivePairingRequest:<\(request)> forDevice:<\(device)>)")
        PairingInterfaceController.showPairingNotification(for: device)
    }
    
    
    // MARK: Private
    
    private func checkOneAppInstanceRunning() {
        let lockFileName = FileManager.default.compatTemporaryDirectory.appendingPathComponent(self.config.hostDeviceId).appendingPathExtension("lock").path
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
        
        let storyboard = NSStoryboard(name: NSStoryboard.Name(rawValue: "WelcomeWindow"), bundle: nil)
        guard let controller = storyboard.instantiateInitialController() as? WelcomeWindowController else { assertionFailure("Could not load welcome window controller."); return }
        
        NSApp.activate(ignoringOtherApps: true)
        
        controller.deviceDataSource = self.deviceManager
        controller.dismissHandler = { [weak self] _ in self?.welcomeWindowController = nil }
        controller.showWindow(nil)
        self.welcomeWindowController = controller
    }
    
    // MARK: WakeUP Function
    
    @objc private func wakeUpListener(_ aNotification: Notification) {
        self.connectionProvider.restart()
        self.updateValidDevices()
    }
    
    // MARK: Extension Support
    
    private func updateValidDevices() {
        self.validDevices = deviceManager.pairedDevices
        validDeviceNames.removeAll(keepingCapacity: false)
        for device in self.validDevices {
            self.validDeviceNames.append(device.name)
        }
        sharedUserDefaults?.set(self.validDeviceNames, forKey: SharedUserDefaults.Keys.devicesToShow)
    }
    
    static func shared() -> AppDelegate {
        return NSApplication.shared.delegate as! AppDelegate
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.notification.request.content.categoryIdentifier == "IncomingCall" {
            userNotificationManager.handleMuteAction(for: response)
        } else if response.notification.request.content.categoryIdentifier == "DownloadFinished" {
            userNotificationManager.handleOpenDownloadedFileAction(for: response)
        }
        else {
            print("Unknown notification category identifier action!")
        }
    }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if #available(macOS 11.0, *) {
            return completionHandler([.list, .sound])
        } else {
            // Fallback on earlier versions
            print("UNNotification system not compatible with macOS Catalina or earlier! Use NSUserNotification instead!")
        }
    }
}
