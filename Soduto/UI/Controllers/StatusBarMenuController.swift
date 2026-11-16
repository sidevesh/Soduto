//
//  StatusBarMenuController.swift
//  Soduto
//
//  Created by Giedrius Stanevicius on 2016-07-26.
//  Copyright © 2016 Soduto. All rights reserved.
//

import Foundation
import AppKit
import ServiceManagement
import UniformTypeIdentifiers
import Combine

public class StatusBarMenuController: NSObject, NSWindowDelegate, NSMenuDelegate, NSDraggingDestination {
    
    @IBOutlet weak var statusBarMenu: NSMenu!
    @IBOutlet weak var availableDevicesItem: NSMenuItem!
    @IBOutlet weak var dashboardMenuItem: NSMenuItem!
    
    public var deviceDataSource: DeviceDataSource?
    public var serviceManager: ServiceManager?
    public var config: Configuration?
    
    let statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var cancellables: Set<AnyCancellable> = []
    /// Persistent references to device menu items keyed by device ID, for in-place image updates
    private var deviceMenuItems: [String: NSMenuItem] = [:]
    /// Toggles media sync (MPRIS, both directions); inserted below "Launch on Login" in `awakeFromNib`
    private let mediaSyncMenuItem = NSMenuItem(title: NSLocalizedString("Sync Media Playback", comment: "Status bar menu item"), action: nil, keyEquivalent: "")
    
    private var settingsWindowController: SettingsWindowController?
    /// The template Soduto icon, shown unless the menu bar is set to show a single connected device's status
    private var sodutoStatusIcon: NSImage?
    private var defaultsObserver: NSObjectProtocol?
    
    private var dashboardWindowController: DeviceDashboardWindowController?
    
    private var dragOperationPerformed: Bool = false
    
    override public func awakeFromNib() {
        let statusBarIcon = #imageLiteral(resourceName: "statusBarIcon")
        statusBarIcon.isTemplate = true
        self.sodutoStatusIcon = statusBarIcon
        
        if #available(macOS 10.14, *) {
            self.statusBarItem.button?.image = statusBarIcon
        } else {
            self.statusBarItem.image = statusBarIcon
        }
        self.statusBarItem.menu = self.statusBarMenu
        
        self.mediaSyncMenuItem.target = self
        self.mediaSyncMenuItem.action = #selector(toggleMediaSync(_:))
        self.mediaSyncMenuItem.toolTip = NSLocalizedString("Mirror media players between this Mac and your devices. Turn off if, for example, headphones paired to both keep pausing playback.", comment: "Status bar menu item tooltip")
        // Frequently toggled, so it sits with Open Dashboard rather than in Settings
        let dashboardIndex = self.statusBarMenu.index(of: self.dashboardMenuItem)
        self.statusBarMenu.insertItem(self.mediaSyncMenuItem, at: dashboardIndex >= 0 ? dashboardIndex + 1 : self.statusBarMenu.numberOfItems)
        
        let dragTypes: [NSPasteboard.PasteboardType] = [
            NSPasteboard.PasteboardType(UTType.url.identifier),
            NSPasteboard.PasteboardType(UTType.text.identifier) ]
        self.statusBarItem.button?.window?.registerForDraggedTypes(dragTypes)
        self.statusBarItem.button?.window?.delegate = self
        
        // Menu bar options are toggled in Settings; follow them live
        self.defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateStatusItemImage() }
        }
    }
    
    private func setupServiceObservers() {
        cancellables.removeAll()
        guard let serviceManager = self.serviceManager else { return }
        
        if let batteryService = serviceManager.service(ofType: BatteryService.self) {
            batteryService.$statuses
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in Task { @MainActor [weak self] in self?.updateDeviceImages() } }
                .store(in: &cancellables)
        }
        
        if let connectivityService = serviceManager.service(ofType: ConnectivityReportService.self) {
            connectivityService.$statuses
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in Task { @MainActor [weak self] in self?.updateDeviceImages() } }
                .store(in: &cancellables)
        }
    }
    
    
    // MARK: Actions
    
    @IBAction func quit(_ sender: Any?) {
        NSApp.terminate(sender)
    }
    
    @objc func toggleMediaSync(_ sender: Any?) {
        guard let mediaPlayerService = self.serviceManager?.service(ofType: MediaPlayerService.self) else { return }
        mediaPlayerService.setMediaSyncEnabled(!mediaPlayerService.isMediaSyncEnabled)
    }
    
    @IBAction func refreshNotifications(_ sender: Any?) {
        AppDelegate.shared().serviceManager.service(ofType: NotificationsService.self)?.refreshNotifications()
        
    }
    
    @IBAction func openPreferences(_ sender: Any?) {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                config: config,
                updateManager: AppDelegate.shared().updateManager,
                onOpenDashboard: { [weak self] in self?.openDashboard(nil) }
            )
        }
        settingsWindowController?.show()
    }
    
    @IBAction func openDashboard(_ sender: Any?) {
        if dashboardWindowController == nil {
            guard let deviceDataSource = deviceDataSource,
                  let serviceManager = serviceManager else { return }
            let controller = DeviceDashboardWindowController(
                deviceDataSource: deviceDataSource,
                deviceManager: AppDelegate.shared().deviceManager,
                mediaPlayerService: serviceManager.service(ofType: MediaPlayerService.self),
                batteryService: serviceManager.service(ofType: BatteryService.self),
                connectivityReportService: serviceManager.service(ofType: ConnectivityReportService.self)
            )
            controller.onClose = { [weak self] in self?.dashboardWindowController = nil }
            dashboardWindowController = controller
        }
        dashboardWindowController?.show()
    }
    
    @IBAction func showAboutWindow(_ sender: Any?) {
        AboutWindowController.showAboutWindow()
    }
    
    
    // MARK: Drag'n'Drop
    
    public dynamic func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragOperationPerformed = false
        for service in self.serviceManager?.services ?? [] {
            guard let destination = service as? NSDraggingDestination else { continue }
            guard let operation = destination.draggingEntered?(sender) else { continue }
            guard !operation.isEmpty else { continue }
            return operation
        }
        return []
    }
    
    public dynamic func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragOperationPerformed = false
        for service in self.serviceManager?.services ?? [] {
            guard let destination = service as? NSDraggingDestination else { continue }
            guard let operation = destination.draggingUpdated?(sender) else { continue }
            guard !operation.isEmpty else { continue }
            return operation
        }
        return []
    }
    
    public dynamic func draggingEnded(_ sender: NSDraggingInfo) {
        for service in self.serviceManager?.services ?? [] {
            guard let destination = service as? NSDraggingDestination else { continue }
            destination.draggingEnded?(sender)
        }
        
        // A workaround for items dragged from dock stack - in such case performDragOperation is not called
        if !dragOperationPerformed && self.statusBarItem.button?.frame.contains(sender.draggingLocation) == true {
            _ = performDragOperation(sender)
        }
    }
    
    public dynamic func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dragOperationPerformed = true
        for service in self.serviceManager?.services ?? [] {
            guard let destination = service as? NSDraggingDestination else { continue }
            guard destination.performDragOperation?(sender) == true else { continue }
            return true
        }
        return false
    }
    
    
    // MARK: NSMenuDelegate
    
    public func menuNeedsUpdate(_ menu: NSMenu) {
        // Removed automatic broadcast - not part of official KDE Connect protocol
        // Only broadcast on: app start, network change, manual Cmd+R
        
        if menu == self.statusBarMenu {
            self.dashboardMenuItem?.isEnabled = true
            self.refreshMenuDeviceList()
            self.mediaSyncMenuItem.state = (self.serviceManager?.service(ofType: MediaPlayerService.self)?.isMediaSyncEnabled ?? false) ? .on : .off
        }
    }
    
    
    // MARK: Public methods
    
    func refreshDeviceLists() {
        self.dashboardWindowController?.refreshDeviceList()
        self.dashboardMenuItem?.isEnabled = true
        Task { @MainActor [weak self] in self?.updateStatusItemImage() }
    }
    
    /// Call this once from AppDelegate after all services have been registered.
    func startServiceObservers() {
        setupServiceObservers()
    }
    
    
    // MARK: Private methods
    
    @MainActor
    private func refreshMenuDeviceList() {
        // Remove all existing device items and clear stored references
        deviceMenuItems.removeAll()
        var item = self.statusBarMenu.item(withTag: InterfaceElementTags.availableDeviceMenuItem.rawValue)
        while item != nil {
            self.statusBarMenu.removeItem(item!)
            item = self.statusBarMenu.item(withTag: InterfaceElementTags.availableDeviceMenuItem.rawValue)
        }
        
        // Re-add device items, storing references for live image updates
        let devices = self.deviceDataSource?.pairedDevices ?? []
        guard devices.count > 0 else { return }
        
        var index = self.statusBarMenu.index(of: self.availableDevicesItem)
        assert(index != -1, "availableDevicesItem expected to be item of statusBarMenu")
        for device in devices {
            let item = NSMenuItem(title: device.name, action: nil, keyEquivalent: "")
            item.tag = InterfaceElementTags.availableDeviceMenuItem.rawValue
            item.submenu = DeviceMenu(device: device)
            item.image = statusImage(for: device)
            index += 1
            self.statusBarMenu.insertItem(item, at: index)
            deviceMenuItems[device.id] = item
        }
    }
    
    /// Updates only the status images on existing device menu items without rebuilding the menu.
    /// Called by service observers for real-time battery/connectivity changes.
    /// Also restores the title defensively as AppKit can drop the title text when the image
    /// is updated while the menu is mid-render (transient layout glitch).
    /// Shows the single connected device's icon / signal / battery in the menu bar when enabled in Settings,
    /// otherwise (or with zero or several connected devices) the Soduto icon.
    @MainActor
    private func updateStatusItemImage() {
        guard let button = statusBarItem.button else { return }
        let connected = deviceDataSource?.pairedRechableDevices ?? []
        if AppDefaultsStore.Preferences.MenuBar.showsDeviceStatus,
           connected.count == 1, let device = connected.first,
           let image = deviceStatusImage(for: device) {
            button.image = image
            button.toolTip = device.name
            statusBarItem.length = NSStatusItem.variableLength
        } else {
            button.image = sodutoStatusIcon
            button.toolTip = nil
            statusBarItem.length = NSStatusItem.squareLength
        }
    }
    
    @MainActor
    private func deviceStatusImage(for device: Device) -> NSImage? {
        let prefs = AppDefaultsStore.Preferences.MenuBar.self
        var fragments: [NSImage] = []
        if prefs.showDeviceIcon {
            let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.labelColor]))
            if let symbol = NSImage(systemSymbolName: device.type.sfSymbolName, accessibilityDescription: device.name)?
                .withSymbolConfiguration(configuration) {
                fragments.append(symbol)
            }
        }
        if prefs.showSignal, let signal = serviceManager?.service(ofType: ConnectivityReportService.self)?.statusBarImage(for: device) {
            fragments.append(signal)
        }
        if prefs.showBattery, let battery = serviceManager?.service(ofType: BatteryService.self)?.statusBarImage(for: device) {
            fragments.append(battery)
        }
        guard !fragments.isEmpty else { return nil }
        
        let spacing: CGFloat = 4
        let height = max(16, fragments.map(\.size.height).max() ?? 16)
        let width = fragments.map(\.size.width).reduce(0, +) + spacing * CGFloat(fragments.count - 1)
        // Drawn lazily, so `labelColor` resolves against the menu bar's current appearance
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for fragment in fragments {
                fragment.draw(in: NSRect(x: x, y: (height - fragment.size.height) / 2, width: fragment.size.width, height: fragment.size.height))
                x += fragment.size.width + spacing
            }
            return true
        }
        image.accessibilityDescription = device.name
        return image
    }
    
    @MainActor
    private func updateDeviceImages() {
        updateStatusItemImage()
        guard let devices = self.deviceDataSource?.pairedDevices else { return }
        for device in devices {
            guard let item = deviceMenuItems[device.id] else { continue }
            if item.title != device.name { item.title = device.name }
            item.image = statusImage(for: device)
        }
    }
    
    @MainActor
    private func statusImage(for device: Device) -> NSImage? {
        guard let serviceManager = self.serviceManager else { return nil }
        
        // Collect image fragments from all services that provide status bar images
        let fragments: [(order: Int, image: NSImage)] = serviceManager.services
            .compactMap { $0 as? StatusBarImageProvider }
            .compactMap { provider in
                guard let image = provider.statusBarImage(for: device) else { return nil }
                return (provider.statusBarImageSortOrder, image)
            }
            .sorted { $0.order < $1.order }
        
        guard !fragments.isEmpty else { return nil }
        
        // Composite all fragments horizontally with spacing between them
        let interSpacing: CGFloat = 2
        let imageHeight: CGFloat = 13
        let totalWidth = fragments.map(\.image.size.width).reduce(0, +) + interSpacing * CGFloat(max(fragments.count - 1, 0))
        
        let image = NSImage(size: CGSize(width: totalWidth, height: imageHeight), flipped: false) { _ in
            var x: CGFloat = 0
            for (index, fragment) in fragments.enumerated() {
                fragment.image.draw(in: NSRect(
                    x: x,
                    y: (imageHeight - fragment.image.size.height) / 2,
                    width: fragment.image.size.width,
                    height: fragment.image.size.height
                ))
                x += fragment.image.size.width + (index < fragments.count - 1 ? interSpacing : 0)
            }
            return true
        }
        
        return image
    }
}
