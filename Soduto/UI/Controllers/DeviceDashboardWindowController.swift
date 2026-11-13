//
//  DeviceDashboardWindowController.swift
//  Soduto
//
//  Created by Sannidhya Roy on 20/03/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import Cocoa
import SwiftUI
import Combine

final class DeviceDashboardWindowController: NSWindowController, NSWindowDelegate {
    
    private(set) var model: DeviceDashboardModel
    private var titleCancellable: AnyCancellable?
    private var localKeyMonitor: Any?
    
    /// Smallest content size at which the sidebar and the player controls fit without crowding.
    private static let minimumContentSize = NSSize(width: 680, height: 460)
    
    init(deviceDataSource: DeviceDataSource,
         mediaPlayerService: MediaPlayerService?,
         batteryService: BatteryService?,
         connectivityReportService: ConnectivityReportService?) {
        let model = DeviceDashboardModel(
            deviceDataSource: deviceDataSource,
            mediaPlayerService: mediaPlayerService,
            batteryService: batteryService,
            connectivityReportService: connectivityReportService
        )
        self.model = model
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "No Devices"
        window.setFrameAutosaveName("DeviceDashboard")
        window.center()
        
        super.init(window: window)
        window.delegate = self
        
        // The hosting controller drives the window's minimum size from the SwiftUI content (overriding
        // `window.minSize`), so the minimum is set on the content and mirrored to the window.
        let rootView = DeviceDashboardView(model: model)
            .frame(minWidth: Self.minimumContentSize.width, minHeight: Self.minimumContentSize.height)
        window.contentViewController = NSHostingController(rootView: rootView)
        window.contentMinSize = Self.minimumContentSize
        
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window,
                  event.modifierFlags.contains(.command),
                  event.charactersIgnoringModifiers == "w" else { return event }
            self.window?.performClose(nil)
            return nil
        }
        
        titleCancellable = model.$selectedDeviceId
            .combineLatest(model.$devices)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (selectedId, devices) in
                if let id = selectedId, let device = devices.first(where: { $0.id == id }) {
                    self?.window?.title = device.device.name
                } else {
                    self?.window?.title = "No Devices"
                }
            }
    }
    
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    
    deinit {
        if let monitor = localKeyMonitor { NSEvent.removeMonitor(monitor) }
    }
    
    // MARK: NSWindowDelegate
    
    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
    
    // MARK: Public
    
    /// Called when the window closes. StatusBarMenuController sets this to nil out
    /// its strong reference, fully releasing the model and all Combine subscriptions.
    var onClose: (() -> Void)?
    
    func show() {
        if window?.isVisible == false {
            // Restore saved frame or fall back to center
            if window?.setFrameUsingName("DeviceDashboard") == false {
                window?.center()
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
    
    func refreshDeviceList() {
        model.refreshDeviceList()
    }
}
