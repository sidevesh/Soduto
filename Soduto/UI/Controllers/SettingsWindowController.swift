//
//  SettingsWindowController.swift
//  Soduto
//
//  Copyright © 2026 Soduto. All rights reserved.
//

import Cocoa
import SwiftUI

/// Hosts `SettingsView` in a standard Settings window (⌘, from the menu bar menu).
final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    private let model: SettingsModel
    private var localKeyMonitor: Any?
    private var runCommandsWindowController: RunCommandsWindowController?

    init(config: Configuration?, updateManager: UpdateManager?, onOpenDashboard: @escaping () -> Void) {
        var editRunCommands: () -> Void = {}
        let model = SettingsModel(
            config: config,
            updateManager: updateManager,
            onEditRunCommands: { editRunCommands() },
            onOpenDashboard: onOpenDashboard
        )
        self.model = model

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = NSLocalizedString("Settings", comment: "Settings window title")
        window.contentViewController = NSHostingController(rootView: SettingsView(model: model))
        window.contentMinSize = NSSize(width: 460, height: 420)
        window.setContentSize(NSSize(width: 500, height: 620))
        window.setFrameAutosaveName("SodutoSettings")
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self
        editRunCommands = { [weak self] in self?.showRunCommands() }

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

    func show() {
        model.reload()
        if window?.isVisible == false, window?.setFrameUsingName("SodutoSettings") == false {
            window?.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func showRunCommands() {
        guard let window else { return }
        if runCommandsWindowController == nil {
            let controller = RunCommandsWindowController()
            controller.delegate = AppDelegate.shared().serviceManager.service(ofType: RunCommandService.self)
            runCommandsWindowController = controller
        }
        runCommandsWindowController?.presentAsSheet(in: window)
    }
}
