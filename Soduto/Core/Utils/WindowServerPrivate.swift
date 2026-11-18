//
//  WindowServerPrivate.swift
//  Soduto
//
//  Copyright © 2026 Soduto. All rights reserved.
//

import Foundation
import CoreGraphics
import ApplicationServices
import os

/// Private WindowServer (CoreGraphics/SkyLight) calls that input-sharing apps such as Barrier, Deskflow
/// and Synergy rely on while they redirect the keyboard and mouse to another device:
///
/// - pausing system keyboard shortcuts (⌘Tab, Mission Control, Spotlight…), which WindowServer handles
///   before any event tap sees the keys
/// - letting a background app hide the cursor (normally only the frontmost app can)
/// - bringing Soduto to the front, which macOS 14+ otherwise refuses to a background app that the user
///   didn't just click (`NSApp.activate` is only a request); the same call window switchers use
///
/// The symbols are resolved at runtime, so if a future macOS drops them the calls simply do nothing.
enum WindowServerPrivate {

    private typealias ConnectionIDFunction = @convention(c) () -> Int32
    private typealias SetHotKeyModeFunction = @convention(c) (Int32, Int32) -> Int32
    private typealias SetConnectionPropertyFunction = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
    private typealias CursorIsVisibleFunction = @convention(c) () -> UInt32
    private typealias GetProcessForPIDFunction = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    private typealias SetFrontProcessFunction = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32) -> Int32

    /// `CGSGlobalHotKeyOperatingMode` values
    private enum HotKeyMode: Int32 {
        case enable = 0
        case disable = 1
    }

    private static let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT

    /// SkyLight hosts the SLS* symbols; AppKit loads it anyway, this just makes sure
    private static let skyLightHandle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    
    private static func function<T>(_ names: [String], as type: T.Type) -> T? {
        for name in names {
            if let pointer = dlsym(defaultHandle, name) ?? skyLightHandle.flatMap({ dlsym($0, name) }) {
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
    
    private static let getProcessForPID: GetProcessForPIDFunction? =
        function(["GetProcessForPID"], as: GetProcessForPIDFunction.self)
    private static let setFrontProcess: SetFrontProcessFunction? =
        function(["_SLPSSetFrontProcessWithOptions", "SLPSSetFrontProcessWithOptions"], as: SetFrontProcessFunction.self)
    
    /// Makes this app the frontmost (active) app with `window` in front, as if the user had chosen it.
    @discardableResult
    static func bringToFront(windowNumber: Int) -> Bool {
        guard let getProcessForPID, let setFrontProcess else {
            Logger.services.notice("WindowServer front process API unavailable")
            return false
        }
        var psn = ProcessSerialNumber()
        guard getProcessForPID(getpid(), &psn) == noErr else { return false }
        let userGenerated: UInt32 = 0x200  // kCPSUserGenerated
        return setFrontProcess(&psn, UInt32(truncatingIfNeeded: windowNumber), userGenerated) == 0
    }
    
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
