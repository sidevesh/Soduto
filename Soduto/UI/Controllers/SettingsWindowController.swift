//
//  SettingsWindowController.swift
//  Soduto
//
//  Copyright © 2026 Soduto. All rights reserved.
//

import Cocoa
import SwiftUI

/// Soduto's Settings window (⌘, from the menu bar menu): the standard macOS layout with icon tabs in
/// the toolbar, each tab a grouped form. The window resizes to fit the selected tab.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    private let model: SettingsModel
    private let runCommandsModel = RunCommandsViewModel()
    private var localKeyMonitor: Any?

    init(config: Configuration?, updateManager: UpdateManager?, deviceDataSource: DeviceDataSource?, onOpenDashboard: @escaping () -> Void) {
        let model = SettingsModel(
            config: config,
            updateManager: updateManager,
            deviceDataSource: deviceDataSource,
            onOpenDashboard: onOpenDashboard
        )
        self.model = model
        runCommandsModel.delegate = AppDelegate.shared().serviceManager.service(ofType: RunCommandService.self)

        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.canPropagateSelectedChildViewControllerTitle = true
        tabs.addTabViewItem(Self.tab("General", symbol: "gearshape", view: GeneralSettingsView(model: model)))
        tabs.addTabViewItem(Self.tab("Menu Bar", symbol: "menubar.rectangle", view: MenuBarSettingsView()))
        tabs.addTabViewItem(Self.tab("Control", symbol: "cursorarrow.motionlines", view: ControlSettingsView(model: model)))
        tabs.addTabViewItem(Self.tab("Run Commands", symbol: "apple.terminal", view: RunCommandsView(viewModel: runCommandsModel).frame(width: 520, height: 420)))
        tabs.addTabViewItem(Self.tab("Updates", symbol: "arrow.triangle.2.circlepath", view: UpdatesSettingsView(model: model)))

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.toolbarStyle = .preference
        window.setFrameAutosaveName("SodutoSettings")
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window,
                  event.modifierFlags.contains(.command),
                  event.charactersIgnoringModifiers == "w" else { return event }
            self.window?.performClose(nil)
            return nil
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let monitor = localKeyMonitor { NSEvent.removeMonitor(monitor) }
    }

    private static func tab<Content: View>(_ title: String, symbol: String, view: Content) -> NSTabViewItem {
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = .preferredContentSize
        controller.title = title
        let item = NSTabViewItem(viewController: controller)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return item
    }

    func show() {
        model.reload()
        runCommandsModel.reload()
        if window?.isVisible == false {
            window?.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: NSWindowDelegate

    /// Accessibility can be granted in System Settings while the window is open
    func windowDidBecomeKey(_ notification: Notification) {
        model.reload()
    }
}
