//
//  ShareExtensionController.swift
//  Soduto Share
//
//  Created by Sannidhya Roy on 03/12/22.
//  Copyright © 2022 Soduto. All rights reserved.
//

import Cocoa
import Combine
import SwiftUI
import UniformTypeIdentifiers
import os

class ShareExtensionController: NSViewController {
    
    /// Each entry is ["id": "<deviceId>", "name": "<displayName>", "type": "<deviceType>"].
    /// Empty when Soduto isn't running and couldn't be started, or no device is reachable.
    lazy var validDeviceEntries: [[String: String]] = Self.loadDevices().map { ["id": $0.id, "name": $0.name, "type": $0.type] }

    /// Soduto.app, which contains this extension (Soduto.app/Contents/PlugIns/Soduto Share.appex)
    private static var hostAppURL: URL {
        Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func openConfiguration() -> NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        return configuration
    }

    /// The devices Soduto published; asks it to publish, and starts it if it isn't running
    private static func loadDevices() -> [AppDefaultsStore.ShareBridge.DeviceEntry] {
        if let devices = AppDefaultsStore.ShareBridge.readDevices() {
            return devices
        }
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(AppDefaultsStore.DarwinNotifications.shareRequestDevices as CFString), nil, nil, true)
        if !waitForDevices(seconds: 0.5) {
            Logger.sharing.info("Soduto isn't running; starting it")
            NSWorkspace.shared.openApplication(at: hostAppURL, configuration: openConfiguration()) { _, error in
                if let error {
                    Logger.sharing.error("Couldn't start Soduto: \(error.localizedDescription, privacy: .public)")
                }
            }
            _ = waitForDevices(seconds: 4)
        }
        return AppDefaultsStore.ShareBridge.readDevices() ?? []
    }

    /// Lets the run loop run (so the launch completes) until devices appear or time runs out
    private static func waitForDevices(seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if AppDefaultsStore.ShareBridge.readDevices() != nil { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return AppDefaultsStore.ShareBridge.readDevices() != nil
    }
    
    lazy var viewModel = ShareViewModel(deviceCount: validDeviceEntries.count)
    weak var touchBarScrubber: NSScrubber?
    private var touchBarStatusCancellable: AnyCancellable?
    
    // MARK: - NSViewController
    
    /// Computes a sheet height that fits the content, capped at a maximum.
    private var sheetHeight: CGFloat {
        guard !validDeviceEntries.isEmpty else { return 240 }
        
        let fixedHeight: CGFloat = 84  // title (~44) + 2 dividers (~2) + footer (~38)
        let columnsPerRow = 4
        let rowCount = Int(ceil(Double(validDeviceEntries.count) / Double(columnsPerRow)))
        let gridHeight = CGFloat(rowCount) * 75        // 56 circle + 6 spacing + 13 text
            + CGFloat(max(0, rowCount - 1)) * 16       // inter-row spacing
            + 32                                       // grid padding (16 top + 16 bottom)
        
        return min(fixedHeight + gridHeight, 400)
    }
    
    override func loadView() {
        let rootView = ShareSheetView(viewModel: viewModel, deviceEntries: validDeviceEntries, onDeviceSelected: { [weak self] index in
            self?.shareToDevice(at: index)
        }, onDismiss: { [weak self] in
            guard let self = self else { return }
            if self.viewModel.hasInitiatedAnyShare {
                self.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
            } else {
                self.cancel(nil)
            }
        })
        
        let height = sheetHeight
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 410, height: height))
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = container.bounds
        hostingView.autoresizingMask = [.width, .height]
        container.addSubview(hostingView)
        
        self.view = container
        self.preferredContentSize = NSSize(width: 410, height: height)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        guard let item = self.extensionContext?.inputItems.first as? NSExtensionItem else { return }
        if let attachments = item.attachments {
            #if DEBUG
                Logger.sharing.debug("Attachments = \(attachments, privacy: .public)")
            #else
                Logger.sharing.debug("Attachments count: \(attachments.count, privacy: .public)")
            #endif
        } else {
            Logger.sharing.debug("No Attachments")
        }
        
        // Refresh TouchBar scrubber when device statuses change
        touchBarStatusCancellable = viewModel.$deviceStatuses
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.touchBarScrubber?.reloadData()
            }
        
        // Soduto pings when transfer statuses change
        let statusNotificationName = AppDefaultsStore.DarwinNotifications.shareStatus as CFString
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(), { _, observer, _, _, _ in
            guard let observer = observer else { return }
            let controller = Unmanaged<ShareExtensionController>.fromOpaque(observer).takeUnretainedValue()
            DispatchQueue.main.async {
                controller.handleStatusUpdate()
            }
        }, statusNotificationName, nil, .deliverImmediately)
    }
    
    override func viewDidAppear() {
        super.viewDidAppear()
        self.view.window?.unbind(NSBindingName(rawValue: #keyPath(touchBar)))
        self.view.window?.bind(NSBindingName(rawValue: #keyPath(touchBar)), to: self, withKeyPath: #keyPath(touchBar), options: nil)
    }
    
    deinit {
        self.view.window?.unbind(NSBindingName(rawValue: #keyPath(touchBar)))
        CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(), nil, nil)
    }
    
    // MARK: - Share Logic
    
    func shareToDevice(at index: Int) {
        // Guard: device must be interactive
        guard viewModel.isInteractive(index) else { return }
        
        // Guard: valid index
        guard index < validDeviceEntries.count else {
            UserNotificationHelper.show(title: "Soduto Share", body: "Selected device is no longer available.", sound: true, id: "DeviceUnavailable", urgency: .active)
            return
        }
        
        // Guard: not currently collecting attachments (prevents race on first tap)
        guard !viewModel.isCollectingAttachments else { return }
        
        // Set transferring state (breathing ring appears)
        viewModel.deviceStatuses[index] = .transferring
        
        if viewModel.cachedURLs != nil {
            // Attachments already cached — hand off immediately
            handOffToMainApp(deviceIndex: index)
        } else {
            // First tap — collect attachments, then hand off
            collectAttachmentsThenHandOff(deviceIndex: index)
        }
    }
    
    @objc func cancel(_ sender: AnyObject?) {
        let cancelError = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError, userInfo: nil)
        self.extensionContext!.cancelRequest(withError: cancelError)
    }
    
    // MARK: - Attachment Collection
    
    private func collectAttachmentsThenHandOff(deviceIndex: Int) {
        guard let content = extensionContext?.inputItems.first as? NSExtensionItem else { return }
        
        viewModel.isCollectingAttachments = true
        
        let group = DispatchGroup()
        let lock = NSLock()
        var collectedURLs: [URL] = []
        var collectedTexts: [String] = []
        
        // macOS share sheet provides shared text via attributedContentText on NSExtensionItem.
        if let attributedText = content.attributedContentText {
            let text = attributedText.string
            if !text.isEmpty {
                collectedTexts.append(text)
            }
        }
        
        for attachment in content.attachments ?? [] {
            if attachment.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                group.enter()
                attachment.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { [weak self] (data, error) in
                    defer { group.leave() }
                    guard self != nil else { return }
                    
                    if let error = error {
                        Logger.sharing.error("Failed to load shared item: \(error.localizedDescription, privacy: .public)")
                        return
                    }
                    guard let data = data as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else {
                        Logger.sharing.error("Failed to create URL from shared data")
                        return
                    }
                    lock.lock()
                    collectedURLs.append(url)
                    lock.unlock()
                }
            } else if collectedTexts.isEmpty && attachment.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                // Safety net: in case an app vends text via NSItemProvider instead of attributedContentText
                group.enter()
                attachment.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { [weak self] (data, error) in
                    defer { group.leave() }
                    guard self != nil else { return }
                    
                    if let error = error {
                        Logger.sharing.error("Failed to load shared text: \(error.localizedDescription, privacy: .public)")
                        return
                    }
                    guard let text = data as? String else {
                        Logger.sharing.error("Failed to read shared text")
                        return
                    }
                    lock.lock()
                    collectedTexts.append(text)
                    lock.unlock()
                }
            }
        }
        
        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            
            // Cache for reuse on subsequent device taps
            self.viewModel.cachedURLs = collectedURLs
            self.viewModel.cachedTexts = collectedTexts
            self.viewModel.isCollectingAttachments = false
            
            self.handOffToMainApp(deviceIndex: deviceIndex)
        }
    }
    
    // MARK: - Handoff to Main App
    
    /// Sends the request (device, texts) to Soduto as a `soduto-share:` link, then opens the files with
    /// Soduto, which gives it access to them
    private func handOffToMainApp(deviceIndex: Int) {
        let deviceId = validDeviceEntries[deviceIndex]["id"] ?? ""
        let urls = viewModel.cachedURLs ?? []
        let texts = viewModel.cachedTexts ?? []
        let fileURLs = urls.filter(\.isFileURL)
        // Web links are shared as text (the device opens them)
        let allTexts = texts + urls.filter { !$0.isFileURL }.map(\.absoluteString)
        
        guard !fileURLs.isEmpty || !allTexts.isEmpty,
              let requestURL = AppDefaultsStore.ShareBridge.url(for: .init(deviceId: deviceId, fileCount: fileURLs.count, texts: allTexts)) else {
            viewModel.deviceStatuses[deviceIndex] = .failed
            return
        }
        AppDefaultsStore.ShareBridge.clearStatus(forDevice: deviceId)
        
        let app = Self.hostAppURL
        NSWorkspace.shared.open([requestURL], withApplicationAt: app, configuration: Self.openConfiguration()) { [weak self] _, error in
            if let error {
                Logger.sharing.error("Couldn't hand the request to Soduto: \(error.localizedDescription, privacy: .public)")
                DispatchQueue.main.async { self?.viewModel.deviceStatuses[deviceIndex] = .failed }
                return
            }
            guard !fileURLs.isEmpty else { return }
            NSWorkspace.shared.open(fileURLs, withApplicationAt: app, configuration: Self.openConfiguration()) { _, error in
                if let error {
                    Logger.sharing.error("Couldn't hand the files to Soduto: \(error.localizedDescription, privacy: .public)")
                    DispatchQueue.main.async { self?.viewModel.deviceStatuses[deviceIndex] = .failed }
                }
            }
        }
    }
    
    // MARK: - Status Updates from Main App
    
    func handleStatusUpdate() {
        let statuses = AppDefaultsStore.ShareBridge.readStatuses()
        for (index, entry) in validDeviceEntries.enumerated() {
            guard let deviceId = entry["id"], let status = statuses[deviceId] else { continue }
            switch status {
            case "success":
                viewModel.deviceStatuses[index] = .sent
            case "failed":
                viewModel.deviceStatuses[index] = .failed
            default:
                break
            }
        }
    }
    
}
