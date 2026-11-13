//
//  AccessibilityPermission.swift
//  Soduto
//
//  Copyright © 2026 Soduto. All rights reserved.
//

import Cocoa
import ApplicationServices
import os

/// The Accessibility permission (posting input events and tapping keyboard/mouse events), shared by
/// Control Device (Mac → device), remote input and presenter (device → Mac) and the digitizer.
enum AccessibilityPermission {

    /// Whether macOS currently trusts this exact build of Soduto.
    static var isGranted: Bool { AXIsProcessTrusted() }

    /// Where the permission lives in System Settings on the running macOS version.
    /// macOS 27 renamed Privacy & Security › Accessibility to "Device Control and Data Access".
    static var settingsLocation: String {
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 {
            return "System Settings › Privacy & Security › Device Control and Data Access"
        }
        return "System Settings › Privacy & Security › Accessibility"
    }

    /// Terminal command that clears Soduto's entry so it can be granted again from scratch.
    static var resetCommand: String {
        "tccutil reset Accessibility \(Bundle.main.bundleIdentifier ?? "com.soduto.Soduto")"
    }

    /// Opens the permission's pane. The `Privacy_Accessibility` anchor still opens the renamed pane on macOS 27.
    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private static var isShowingAlert = false

    /// Returns true when access is granted. Otherwise asks macOS to list Soduto (system prompt where supported)
    /// and shows an alert explaining how to grant access.
    ///
    /// - Parameters:
    ///   - feature: short name of what needs the permission, e.g. "Control Device"
    ///   - purpose: one sentence on what the permission is used for
    @discardableResult
    static func requestIfNeeded(feature: String, purpose: String) -> Bool {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        if AXIsProcessTrustedWithOptions(options) { return true }
        Logger.services.notice("Accessibility permission missing for \(feature, privacy: .public)")
        showAlert(
            title: "Allow Soduto to Control This Mac",
            message: "\(purpose)\n\nTurn on Soduto in \(settingsLocation)."
        )
        return false
    }

    /// Shown when access looks granted but macOS still refuses (event tap creation fails).
    static func showStaleGrantAlert(feature: String) {
        showAlert(
            title: "\(feature) Couldn't Start",
            message: "macOS didn't let Soduto capture keyboard and mouse input. This usually means the permission belongs to an earlier build of Soduto."
        )
    }

    private static func showAlert(title: String, message: String) {
        DispatchQueue.main.async {
            guard !isShowingAlert else { return }
            isShowingAlert = true
            defer { isShowingAlert = false }

            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = title
            alert.informativeText = message + "\n\nIf Soduto is already turned on there, it was granted to a different build of Soduto (every new build counts as a new app). Select Soduto, remove it with the − button, add it again, then reopen Soduto. You can also reset it from Terminal with the command below."

            let command = NSTextField(labelWithString: resetCommand)
            command.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            command.isSelectable = true
            command.sizeToFit()
            alert.accessoryView = command

            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Copy Command")
            alert.addButton(withTitle: "Not Now")

            NSApp.activate(ignoringOtherApps: true)
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                openSettings()
            case .alertSecondButtonReturn:
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(resetCommand, forType: .string)
            default:
                break
            }
        }
    }
}
