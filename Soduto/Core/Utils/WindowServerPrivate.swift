//
//  WindowServerPrivate.swift
//  Soduto
//
//  Copyright © 2026 Soduto. All rights reserved.
//

import Foundation
import CoreGraphics
import os

/// Private WindowServer (CoreGraphics/SkyLight) calls that input-sharing apps such as Barrier, Deskflow
/// and Synergy rely on while they redirect the keyboard and mouse to another device:
///
/// - pausing system keyboard shortcuts (⌘Tab, Mission Control, Spotlight…), which WindowServer handles
///   before any event tap sees the keys
/// - letting a background app hide the cursor (normally only the frontmost app can)
///
/// The symbols are resolved at runtime, so if a future macOS drops them the calls simply do nothing.
enum WindowServerPrivate {

    private typealias ConnectionIDFunction = @convention(c) () -> Int32
    private typealias SetHotKeyModeFunction = @convention(c) (Int32, Int32) -> Int32
    private typealias SetConnectionPropertyFunction = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
    private typealias CursorIsVisibleFunction = @convention(c) () -> UInt32

    /// `CGSGlobalHotKeyOperatingMode` values
    private enum HotKeyMode: Int32 {
        case enable = 0
        case disable = 1
    }

    private static let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT

    private static func function<T>(_ names: [String], as type: T.Type) -> T? {
        for name in names {
            if let pointer = dlsym(defaultHandle, name) {
                return unsafeBitCast(pointer, to: type)
            }
        }
        return nil
    }

    private static let mainConnectionID: ConnectionIDFunction? =
        function(["CGSMainConnectionID", "_CGSDefaultConnection", "SLSMainConnectionID"], as: ConnectionIDFunction.self)
    private static let setHotKeyMode: SetHotKeyModeFunction? =
        function(["CGSSetGlobalHotKeyOperatingMode", "SLSSetGlobalHotKeyOperatingMode"], as: SetHotKeyModeFunction.self)
    private static let setConnectionProperty: SetConnectionPropertyFunction? =
        function(["CGSSetConnectionProperty", "SLSSetConnectionProperty"], as: SetConnectionPropertyFunction.self)
    /// `CGCursorIsVisible` is still exported but no longer callable from Swift
    private static let cursorIsVisible: CursorIsVisibleFunction? =
        function(["CGCursorIsVisible", "CGSCursorIsVisible"], as: CursorIsVisibleFunction.self)
    
    /// Whether the cursor is currently shown, or nil if that can't be determined
    static var isCursorVisible: Bool? {
        cursorIsVisible.map { $0() != 0 }
    }

    /// Pauses (or resumes) system-wide keyboard shortcuts for this app's WindowServer connection.
    /// WindowServer restores them on its own if the app quits or crashes.
    @discardableResult
    static func setSystemShortcutsEnabled(_ enabled: Bool) -> Bool {
        guard let connection = mainConnectionID?(), let setHotKeyMode else {
            Logger.services.notice("WindowServer hot key mode API unavailable")
            return false
        }
        let mode: HotKeyMode = enabled ? .enable : .disable
        return setHotKeyMode(connection, mode.rawValue) == 0
    }

    /// Allows `CGDisplayHideCursor` to take effect while Soduto isn't the frontmost app.
    @discardableResult
    static func allowCursorHidingInBackground() -> Bool {
        guard let connection = mainConnectionID?(), let setConnectionProperty else {
            Logger.services.notice("WindowServer connection property API unavailable")
            return false
        }
        return setConnectionProperty(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue) == 0
    }
}
