//
//  RemoteControlService.swift
//  Soduto
//
//  Created by Swapnil Devesh on 2025-04-27.
//  Copyright © 2025 Soduto. All rights reserved.
//

import Foundation
import Cocoa
import os

/// Service for sending keyboard and mouse input from this Mac to a remote device.
///
/// Implements the outgoing side of the `kdeconnect.mousepad` protocol. While capturing, every Mac keyboard,
/// mouse and trackpad event is intercepted by a CGEvent tap and forwarded as `kdeconnect.mousepad.request`
/// packets. Like other input-sharing apps, capture also:
/// - taps at the HID level, where events enter WindowServer: that is before it matches system keyboard
///   shortcuts (⌘Tab, ⌃↑ Mission Control, Spotlight…) and before it moves the cursor, so swallowed events
///   do neither (a session-level tap only sees events after both)
/// - detaches the cursor from the mouse (`CGAssociateMouseAndMouseCursorPosition`) and hides it, and keeps
///   re-applying both, because WindowServer resets them when Spaces or the active app change
/// - swallows trackpad gesture events (Mission Control / Spaces swipes, pinch, rotate)
/// - also pauses system keyboard shortcuts through WindowServer as a second line of defence
///
/// Two ways in, sharing one capture session so they can't conflict:
/// - **Control Device** (menu action): manual mode, until ⌥⎋
/// - **Screen edge** (`kdeconnect.shareinputdevices`, when enabled in Settings): pushing the pointer past
///   the configured edge hands control over; the device hands it back (`releaseDelta…`) when its pointer
///   leaves through the same edge. ⌥⎋ works here too.
///
/// Requires the Accessibility permission (see `AccessibilityPermission` for where it lives per macOS version).
public class RemoteControlService: OutgoingService, ObservableObject {
    
    // MARK: ServiceBase
    
    public var userDefaults: UserDefaults = .standard
    public let outgoingPreferenceKey = AppDefaultsStore.Preferences.Services.RemoteControl.outgoingKey
    
    // MARK: Types
    
    enum CaptureMode: Equatable {
        /// Started from the menu; ends with ⌥⎋
        case manual
        /// Started by pushing past `edge`; ends when the device hands control back, or with ⌥⎋
        case edge(ScreenEdge)
    }
    
    // MARK: Properties
    
    public static let serviceId: Service.Id = "com.soduto.services.remotecontrol"
    
    public let incomingCapabilities = Set<Service.Capability>([
        DataPacket.mousePadKeyboardStatePacketType,
        DataPacket.shareInputDevicesPacketType
    ])
    public var outgoingCapabilities: Set<Service.Capability> {
        outgoingEnabled ? [DataPacket.mousePadRequestPacketType, DataPacket.shareInputDevicesRequestPacketType] : []
    }
    
    @Published public private(set) var isCapturing = false
    private(set) var captureMode: CaptureMode?
    
    /// Last `kdeconnect.mousepad.keyboardstate` reported per device: whether it can receive typed keys
    /// (KDE Connect Android needs its "Keyboard receiver (via accessibility)" or Remote Keyboard enabled).
    private var remoteKeyboardStates: [Device.Id: Bool] = [:]
    
    /// Paired, reachable devices, for picking the screen-edge target
    private var connectedDevices: [Device.Id: Device] = [:]
    
    private let overlay = ControlOverlay()
    private let edgeTrigger = ScreenEdgeTrigger()
    private var defaultsObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?
    
    private var targetDevice: Device?
    private var eventTap: CFMachPort?
    private var eventRunLoopSource: CFRunLoopSource?
    private var optionKeyPressed = false
    private var isDragging = false
    private var escapeMonitor: Any?
    /// How many times this session hid the cursor (hiding is counted; showing must balance it)
    private var cursorHideCount = 0
    private var cursorGuardTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var areSystemShortcutsPaused = false
    
    /// Exposes the connected device type to the CGEvent tap callback (which has no `self`).
    var targetDeviceType: DeviceType? { targetDevice?.type }
    
    // Scroll/swipe accumulation while capturing
    private var lockScrollAccumDx: Double = 0
    private var lockScrollAccumDy: Double = 0
    private var lockScrollStart: Date?
    
    /// Trackpad gesture event types (NSEvent.EventType raw values), swallowed while capturing so Mission
    /// Control, Spaces swipes, Launchpad pinch, Look Up etc. don't act on the Mac. Several of these have no
    /// public `CGEventType` case, hence raw values.
    fileprivate static let gestureEventTypes: [UInt32] = [
        18, // rotate
        19, // beginGesture
        20, // endGesture
        29, // gesture (includes the Dock's Mission Control / Spaces swipe tracking)
        30, // magnify
        31, // swipe
        32, // smartMagnify
        33, // quickLook
        34  // pressure (Force Touch)
    ]
    
    
    // MARK: Init
    
    public init() {
        edgeTrigger.onTrigger = { [weak self] edge, along in
            self?.edgeTriggered(edge: edge, along: along)
        }
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.updateEdgeTrigger()
        }
        // Never leave the cursor hidden or shortcuts paused behind
        terminateObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.stopCapturing()
        }
    }
    
    
    // MARK: Service
    
    public func handleDataPacket(_ dataPacket: DataPacket, fromDevice device: Device, onConnection connection: Connection) -> Bool {
        switch dataPacket.type {
        case DataPacket.mousePadKeyboardStatePacketType:
            if let state = dataPacket.body["state"] as? NSNumber {
                remoteKeyboardStates[device.id] = state.boolValue
            }
            return true
        case DataPacket.shareInputDevicesPacketType:
            handleControlReleased(dataPacket, from: device)
            return true
        default:
            return false
        }
    }
    
    public func setup(for device: Device) {
        guard device.pairingStatus == .Paired else { return }
        connectedDevices[device.id] = device
        updateEdgeTrigger()
    }
    
    public func cleanup(for device: Device) {
        remoteKeyboardStates.removeValue(forKey: device.id)
        connectedDevices.removeValue(forKey: device.id)
        if targetDevice?.id == device.id {
            stopCapturing()
        }
        updateEdgeTrigger()
    }
    
    
    // MARK: Actions
    
    private enum ActionId: Int {
        case startInputCapturing = 1
        case stopInputCapturing = 2
    }
    
    public func actions(for device: Device) -> [ServiceAction] {
        guard outgoingEnabled, device.pairingStatus == .Paired, device.isReachable else { return [] }
        if isCapturing && targetDevice?.id == device.id {
            return [ServiceAction(id: ActionId.stopInputCapturing.rawValue,
                                  title: "Stop Controlling Device",
                                  description: "Release the mouse and keyboard (⌥⎋)",
                                  service: self, device: device)]
        }
        return [ServiceAction(id: ActionId.startInputCapturing.rawValue,
                              title: "Control Device",
                              description: "Use this Mac's mouse and keyboard on the device; press ⌥⎋ to stop",
                              service: self, device: device)]
    }
    
    public func performAction(_ id: ServiceAction.Id, forDevice device: Device, userInfo: [String: Any]?) {
        switch id {
        case ActionId.startInputCapturing.rawValue:
            startCapturing(for: device, mode: .manual)
        case ActionId.stopInputCapturing.rawValue:
            stopCapturing()
        default:
            Logger.services.notice("Unknown action id: \(id, privacy: .public)")
        }
    }
    
    
    // MARK: Screen edge
    
    /// Whether a device supports the screen-edge handover (needs KDE Connect's "Input devices receiver")
    static func supportsEdgeControl(_ device: Device) -> Bool {
        device.incomingCapabilities.contains(DataPacket.shareInputDevicesRequestPacketType)
    }
    
    /// The device the screen edge hands control to: the one chosen in Settings, or else the only
    /// connected device that supports it
    var edgeTargetDevice: Device? {
        let chosenId = AppDefaultsStore.Preferences.EdgeControl.deviceId
        let candidates = connectedDevices.values.filter { $0.isReachable && Self.supportsEdgeControl($0) }
        if !chosenId.isEmpty {
            return candidates.first { $0.id == chosenId }
        }
        return candidates.count == 1 ? candidates.first : nil
    }
    
    /// Runs the edge watcher only while edge control is on and its device is connected (and not while capturing)
    private func updateEdgeTrigger() {
        let prefs = AppDefaultsStore.Preferences.EdgeControl.self
        guard outgoingEnabled, prefs.isEnabled, !isCapturing, edgeTargetDevice != nil,
              let edge = ScreenEdge(rawValue: prefs.edge) else {
            edgeTrigger.stop()
            return
        }
        edgeTrigger.start(edge: edge)
    }
    
    private func edgeTriggered(edge: ScreenEdge, along: CGFloat) {
        guard !isCapturing, let device = edgeTargetDevice else { return }
        Logger.services.info("Pointer pushed past the \(edge.rawValue, privacy: .public) edge; handing control to \(device.name, privacy: .public)")
        guard startCapturing(for: device, mode: .edge(edge)) else { return }
        // Tell the device where the pointer left this Mac; it places its pointer at the matching edge
        let position = Int(along.rounded())
        device.send(DataPacket(type: DataPacket.shareInputDevicesRequestPacketType, body: [
            "exitEdge": edge.qtEdge as NSNumber,
            "deltax": position as NSNumber,
            "deltay": position as NSNumber
        ]))
    }
    
    /// The device's pointer left through the edge it entered from: give the keyboard and mouse back and
    /// put the Mac pointer where it crossed
    private func handleControlReleased(_ packet: DataPacket, from device: Device) {
        guard case .edge(let edge) = captureMode, targetDevice?.id == device.id else { return }
        let releaseX = (packet.body["releaseDeltax"] as? NSNumber)?.doubleValue ?? 0
        let releaseY = (packet.body["releaseDeltay"] as? NSNumber)?.doubleValue ?? 0
        stopCapturing()
        placePointer(at: edge, along: CGFloat(edge == .left || edge == .right ? releaseY : releaseX))
        edgeTrigger.disarmUntilPointerLeavesEdge()
    }
    
    /// Warps the pointer just inside `edge` of the main display, `along` points from its top/left
    private func placePointer(at edge: ScreenEdge, along: CGFloat) {
        let bounds = CGDisplayBounds(CGMainDisplayID())  // global coordinates, origin top-left
        let inset: CGFloat = 2
        let point: CGPoint
        switch edge {
        case .left:
            point = CGPoint(x: bounds.minX + inset, y: bounds.minY + min(max(along, 0), bounds.height - 1))
        case .right:
            point = CGPoint(x: bounds.maxX - 1 - inset, y: bounds.minY + min(max(along, 0), bounds.height - 1))
        case .top:
            point = CGPoint(x: bounds.minX + min(max(along, 0), bounds.width - 1), y: bounds.minY + inset)
        case .bottom:
            point = CGPoint(x: bounds.minX + min(max(along, 0), bounds.width - 1), y: bounds.maxY - 1 - inset)
        }
        CGWarpMouseCursorPosition(point)
    }
    
    
    // MARK: Capturing
    
    /// Starts capturing for `device`. Ignored (returns false) while a capture is already running, so the
    /// menu action and the screen edge can't start overlapping sessions.
    @discardableResult
    func startCapturing(for device: Device, mode: CaptureMode) -> Bool {
        guard !isCapturing, device.pairingStatus == .Paired else { return false }
        
        guard AccessibilityPermission.requestIfNeeded(
            feature: "Control Device",
            purpose: "Soduto sends this Mac's keyboard and mouse input to \(device.name). It needs permission to capture that input."
        ) else { return false }
        
        Logger.services.info("Starting input capture for device: \(device.name, privacy: .public)")
        targetDevice = device
        captureMode = mode
        isCapturing = true
        isDragging = false
        optionKeyPressed = false
        edgeTrigger.stop()
        
        // Without the tap nothing is forwarded and Option+Escape can't be caught, so never hide the cursor then
        guard setupEventTap() else {
            isCapturing = false
            captureMode = nil
            targetDevice = nil
            AccessibilityPermission.showStaleGrantAlert(feature: "Control Device")
            updateEdgeTrigger()
            return false
        }
        setupEscapeMonitor()
        detachAndHideCursor()
        areSystemShortcutsPaused = WindowServerPrivate.setSystemShortcutsEnabled(false)
        showOverlay(for: device, mode: mode)
        return true
    }
    
    func stopCapturing() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.stopCapturing() }
            return
        }
        guard isCapturing else { return }
        
        Logger.services.info("Stopping input capture")
        isCapturing = false
        
        if isDragging, let device = targetDevice {
            sendMouseUp(to: device)
            isDragging = false
        }
        targetDevice = nil
        captureMode = nil
        
        removeEventTap()
        removeEscapeMonitor()
        if areSystemShortcutsPaused {
            WindowServerPrivate.setSystemShortcutsEnabled(true)
            areSystemShortcutsPaused = false
        }
        reattachAndShowCursor()
        overlay.hide()
        
        // Stopping with ⌥⎋ leaves the pointer wherever it was; at the trigger edge, that must not hand
        // control straight back (restart the watcher first: starting it re-arms it)
        updateEdgeTrigger()
        edgeTrigger.disarmUntilPointerLeavesEdge()
        
        Logger.services.info("Input capture stopped")
    }
    
    private func showOverlay(for device: Device, mode: CaptureMode) {
        let hint: String
        switch mode {
        case .manual:
            hint = "Press ⌥⎋ to return to this Mac"
        case .edge(let edge):
            hint = "Move back past the \(edge.title.lowercased()) edge, or press ⌥⎋"
        }
        let note = remoteKeyboardStates[device.id] == false
            ? "Typing needs KDE Connect’s keyboard receiver turned on"
            : nil
        overlay.show(deviceName: device.name, symbolName: device.type.sfSymbolName, hint: hint, note: note)
    }
    
    
    // MARK: Cursor management
    
    /// The cursor stays exactly where it is (mouse deltas still arrive in the tap) and disappears, also
    /// during drags; no warping back to the centre on every event.
    ///
    /// WindowServer undoes both when the active Space or app changes (Mission Control, a notification
    /// taking focus, an app launching), so they are re-applied on those changes and on a short timer.
    private func detachAndHideCursor() {
        // A background app can only hide the cursor with this connection property set
        WindowServerPrivate.allowCursorHidingInBackground()
        CGAssociateMouseAndMouseCursorPosition(0)
        hideCursor()
        
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.reassertCursorCapture()
        }
        RunLoop.main.add(timer, forMode: .common)
        cursorGuardTimer = timer
        
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.reassertCursorCapture()
            })
        }
    }
    
    private func reassertCursorCapture() {
        guard isCapturing else { return }
        CGAssociateMouseAndMouseCursorPosition(0)
        if CGCursorIsVisible() != 0 {
            WindowServerPrivate.allowCursorHidingInBackground()
            hideCursor()
        }
    }
    
    private func hideCursor() {
        if CGDisplayHideCursor(CGMainDisplayID()) == .success {
            cursorHideCount += 1
        }
    }
    
    private func reattachAndShowCursor() {
        cursorGuardTimer?.invalidate()
        cursorGuardTimer = nil
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(center.removeObserver)
        workspaceObservers.removeAll()
        
        CGAssociateMouseAndMouseCursorPosition(1)
        // Showing more often than WindowServer still counts is harmless; showing too rarely isn't
        for _ in 0..<cursorHideCount {
            CGDisplayShowCursor(CGMainDisplayID())
        }
        cursorHideCount = 0
    }
    
    
    // MARK: Event tap
    
    /// Returns false when the tap can't be created (usually missing or stale Accessibility permission).
    private func setupEventTap() -> Bool {
        var eventMask: CGEventMask = [
            CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged,
            .scrollWheel, .keyDown, .keyUp, .flagsChanged
        ].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        for rawType in Self.gestureEventTypes {
            eventMask |= CGEventMask(1) << CGEventMask(rawType)
        }
        
        // HID level: ahead of WindowServer's shortcut handling and cursor movement (see the type comment)
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        ) else {
            Logger.services.error("Failed to create CGEvent tap for remote control")
            return false
        }
        
        eventTap = tap
        eventRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source = eventRunLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }
    
    private func removeEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = eventRunLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
                eventRunLoopSource = nil
            }
            eventTap = nil
        }
    }
    
    
    // MARK: Escape monitor
    
    // Backup local monitor: catches Option+Escape if CGEvent tap is auto-disabled by macOS (slow callbacks),
    // and blocks modifiers from leaking to foreground apps while capturing.
    private func setupEscapeMonitor() {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, self.isCapturing else { return event }
            if event.type == .flagsChanged {
                self.optionKeyPressed = event.modifierFlags.contains(.option)
                return nil
            }
            if event.keyCode == 53 && (event.modifierFlags.contains(.option) || self.optionKeyPressed) {
                DispatchQueue.main.async { self.stopCapturing() }
                return nil
            }
            return nil

        }
    }
    
    private func removeEscapeMonitor() {
        if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
            escapeMonitor = nil
        }
    }
    
    
    // MARK: Packet sending
    
    func sendMouseMove(dx: CGFloat, dy: CGFloat, to device: Device) {
        device.send(DataPacket(type: DataPacket.mousePadRequestPacketType, body: [
            "dx": dx as NSNumber,
            "dy": dy as NSNumber
        ]))
    }
    
    func sendScroll(dx: Double, dy: Double, to device: Device) {
        // Scale raw macOS pixel/line deltas down to values Android expects (~1–5 per event)
        let scale = 0.2
        device.send(DataPacket(type: DataPacket.mousePadRequestPacketType, body: [
            "scroll": true as NSNumber,
            "dx": dx * scale as NSNumber,
            "dy": dy * scale as NSNumber
        ]))
    }
    
    func sendSingleClick(to device: Device) {
        device.send(DataPacket(type: DataPacket.mousePadRequestPacketType, body: ["singleclick": true as NSNumber]))
    }
    
    func sendMouseDown(to device: Device) {
        device.send(DataPacket(type: DataPacket.mousePadRequestPacketType, body: ["singlehold": true as NSNumber]))
    }
    
    func sendMouseUp(to device: Device) {
        device.send(DataPacket(type: DataPacket.mousePadRequestPacketType, body: ["singlerelease": true as NSNumber]))
    }
    
    func sendDoubleClick(to device: Device) {
        device.send(DataPacket(type: DataPacket.mousePadRequestPacketType, body: ["doubleclick": true as NSNumber]))
    }
    
    func sendRightClick(to device: Device) {
        device.send(DataPacket(type: DataPacket.mousePadRequestPacketType, body: ["rightclick": true as NSNumber]))
    }
    
    func sendMiddleClick(to device: Device) {
        device.send(DataPacket(type: DataPacket.mousePadRequestPacketType, body: ["middleclick": true as NSNumber]))
    }
    
    func sendKey(_ key: String, shift: Bool, ctrl: Bool, alt: Bool, command: Bool = false, to device: Device) {
        var body: DataPacket.Body = ["key": key as NSString, "sendAck": false as NSNumber]
        if shift   { body["shift"] = true as NSNumber }
        if ctrl    { body["ctrl"]  = true as NSNumber }
        if alt     { body["alt"]   = true as NSNumber }
        if command { body["super"] = true as NSNumber }
        device.send(DataPacket(type: DataPacket.mousePadRequestPacketType, body: body))
        Logger.services.debug("Remote control: sent key (\(key.count, privacy: .public) chars, ctrl=\(ctrl, privacy: .public)) to \(device.name, privacy: .public)")
    }
    
    func sendSpecialKey(_ keyCode: Int, shift: Bool, ctrl: Bool, alt: Bool, command: Bool = false, to device: Device) {
        var body: DataPacket.Body = ["specialKey": keyCode as NSNumber, "sendAck": false as NSNumber]
        if shift   { body["shift"] = true as NSNumber }
        if ctrl    { body["ctrl"]  = true as NSNumber }
        if alt     { body["alt"]   = true as NSNumber }
        if command { body["super"] = true as NSNumber }
        device.send(DataPacket(type: DataPacket.mousePadRequestPacketType, body: body))
    }
    
    // Android navigation: click mappings are standard across KDE Connect Android clients, similar to a physical keyboard.
    // rightclick → Back, middleclick → Home, doubleclick → Recents.
    func sendBack(to device: Device)    { sendRightClick(to: device) }
    func sendHome(to device: Device)    { sendMiddleClick(to: device) }
    func sendRecents(to device: Device) { sendDoubleClick(to: device) }
    
    /// True when the peer is (inferred to be) KDE Connect Android, i.e. a phone or tablet.
    /// Used in the CGEvent tap to decide between spoon-feeding vs raw passthrough.
    var isVanillaAndroid: Bool {
        targetDevice?.type == .Phone || targetDevice?.type == .Tablet
    }
    
    // Touch drag swipe: press → move → release, then restore pointer to avoid drift.
    func sendSwipe(dx: Double, dy: Double, to device: Device) {
        sendMouseDown(to: device)
        sendMouseMove(dx: CGFloat(dx), dy: CGFloat(dy), to: device)
        sendMouseUp(to: device)
        sendMouseMove(dx: -CGFloat(dx), dy: -CGFloat(dy), to: device)
    }
    
    
    // MARK: Event tap callback
    
    private let eventTapCallback: CGEventTapCallBack = { proxy, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let service = Unmanaged<RemoteControlService>.fromOpaque(refcon).takeUnretainedValue()
        
        // macOS disables a tap whose callback was too slow, or on secure input; turn it straight back on
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if service.isCapturing, let tap = service.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        
        guard service.isCapturing, let device = service.targetDevice else {
            return Unmanaged.passUnretained(event)
        }
        
        // Trackpad gestures (Mission Control, Spaces, Launchpad pinch, Look Up…) must not act on the Mac
        if RemoteControlService.gestureEventTypes.contains(type.rawValue) {
            return nil
        }
        
        let eventType = CGEventType(rawValue: type.rawValue) ?? .null
        
        switch eventType {
            
        // MARK: Mouse movement
        case .mouseMoved:
            let dx = event.getDoubleValueField(.mouseEventDeltaX)
            let dy = event.getDoubleValueField(.mouseEventDeltaY)
            // The cursor is detached from the mouse while capturing, so it doesn't move; only the deltas matter
            if abs(dx) > 0.5 || abs(dy) > 0.5 {
                service.sendMouseMove(dx: CGFloat(dx), dy: CGFloat(dy), to: device)
            }
            return nil
            
        // MARK: Left mouse
        case .leftMouseDown:
            if event.getIntegerValueField(.mouseEventClickState) == 2 {
                service.sendDoubleClick(to: device)
            } else {
                service.isDragging = true
                service.sendMouseDown(to: device)
            }
            return nil
            
        case .leftMouseUp:
            // Release only if drag/press is in progress. isDragging is false after doubleclick,
            // so the trailing mouseUp is swallowed (no spurious singlerelease).
            if service.isDragging {
                service.isDragging = false
                service.sendMouseUp(to: device)
            }
            return nil
            
        case .leftMouseDragged:
            let dx = event.getDoubleValueField(.mouseEventDeltaX)
            let dy = event.getDoubleValueField(.mouseEventDeltaY)
            if !service.isDragging {
                service.isDragging = true
                service.sendMouseDown(to: device)
            }
            if abs(dx) > 0.5 || abs(dy) > 0.5 {
                service.sendMouseMove(dx: CGFloat(dx), dy: CGFloat(dy), to: device)
            }
            return nil
            
        // MARK: Right mouse
        case .rightMouseDown:
            service.sendRightClick(to: device)
            return nil
            
        case .rightMouseUp:
            return nil
            
        case .rightMouseDragged:
            let dx = event.getDoubleValueField(.mouseEventDeltaX)
            let dy = event.getDoubleValueField(.mouseEventDeltaY)
            if abs(dx) > 0.5 || abs(dy) > 0.5 {
                service.sendMouseMove(dx: CGFloat(dx), dy: CGFloat(dy), to: device)
            }
            return nil
            
        // MARK: Middle mouse
        case .otherMouseDown:
            service.sendMiddleClick(to: device)
            return nil
            
        case .otherMouseUp:
            return nil
            
        case .otherMouseDragged:
            let dx = event.getDoubleValueField(.mouseEventDeltaX)
            let dy = event.getDoubleValueField(.mouseEventDeltaY)
            if abs(dx) > 0.5 || abs(dy) > 0.5 {
                service.sendMouseMove(dx: CGFloat(dx), dy: CGFloat(dy), to: device)
            }
            return nil
            
        // MARK: Scroll / swipe
        case .scrollWheel:
            // Use NSEvent's scrollingDeltaX/Y (pixel values).
            // CGEvent's scrollWheelEventDeltaAxis fields return integer line counts which are
            // often 0 on modern trackpads that use precise pixel scrolling.
            guard let nsEvent = NSEvent(cgEvent: event) else { return nil }
            let dx = Double(nsEvent.scrollingDeltaX)
            let dy = Double(nsEvent.scrollingDeltaY)
            
            // Always send scroll in real-time
            if abs(dx) > 0.01 || abs(dy) > 0.01 {
                service.sendScroll(dx: dx, dy: dy, to: device)
            }
            
            // Quick two-finger flick → touch-drag swipe on the device
            switch nsEvent.phase {
            case .began:
                service.lockScrollAccumDx = dx
                service.lockScrollAccumDy = dy
                service.lockScrollStart = Date()
            case .changed:
                service.lockScrollAccumDx += dx
                service.lockScrollAccumDy += dy
            case .ended:
                if let start = service.lockScrollStart {
                    let elapsed = Date().timeIntervalSince(start)
                    let magnitude = hypot(service.lockScrollAccumDx, service.lockScrollAccumDy)
                    if elapsed < 0.35 && magnitude > 30 {
                        service.sendSwipe(dx: service.lockScrollAccumDx, dy: service.lockScrollAccumDy, to: device)
                    }
                }
                service.lockScrollAccumDx = 0; service.lockScrollAccumDy = 0; service.lockScrollStart = nil
            default: break
            }
            return nil
            
        // MARK: Keyboard
        case .keyDown:
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags
            let optionDown = flags.contains(.maskAlternate) || service.optionKeyPressed
            
            // Option+Escape is ALWAYS handled here — never forwarded to the device.
            if keyCode == 53 && optionDown {
                DispatchQueue.main.async { service.stopCapturing() }
                return nil
            }
            
            let isMobile = service.targetDeviceType == .Phone || service.targetDeviceType == .Tablet
            if isMobile {
                let cmd   = flags.contains(.maskCommand)
                let shift = flags.contains(.maskShift)
                let ctrl  = flags.contains(.maskControl)
                let noAlt = !flags.contains(.maskAlternate)
                
                // Android navigation shortcuts. Consume them so they don't also appear as forwarded key packets.
                if cmd && noAlt && !ctrl, let device = service.targetDevice {
                    switch (keyCode, shift) {
                    case (33, false): DispatchQueue.main.async { service.sendBack(to: device) };       return nil  // Cmd+[       → Back
                    case ( 4,  true): DispatchQueue.main.async { service.sendHome(to: device) };       return nil  // Cmd+Shift+H → Home
                    case (15,  true): DispatchQueue.main.async { service.sendRecents(to: device) };    return nil  // Cmd+Shift+R → Recents
                    default: break
                    }
                }
            }
            
            let shift   = flags.contains(.maskShift)
            let ctrl    = flags.contains(.maskControl)
            let alt     = flags.contains(.maskAlternate)
            let command = flags.contains(.maskCommand)
            
            if let specialKey = kdeSpecialKey(for: keyCode) {
                service.sendSpecialKey(specialKey, shift: shift, ctrl: ctrl, alt: alt, command: command, to: device)
            } else {
                // KDE Connect Android: spoon-feed event.characters. Other targets: base glyph + modifiers.
                // With Control held, `characters` is an ASCII control character (Ctrl+C → "\u{3}"), which
                // KDE Connect Android's keyboard receiver can't match against its Ctrl+C/V/X/A handling,
                // so send the plain key instead (`charactersIgnoringModifiers` only keeps Shift's effect).
                let key: String
                if service.isVanillaAndroid {
                    let fromEvent = NSEvent(cgEvent: event).flatMap { ctrl ? $0.charactersIgnoringModifiers : $0.characters }
                    // Translate with the current layout ourselves if the HID-level event carries no text
                    key = (fromEvent?.isEmpty == false ? fromEvent : nil)
                        ?? translatedCharacters(for: keyCode, shift: shift, option: alt && !ctrl,
                                                capsLock: flags.contains(.maskAlphaShift))
                        ?? ""
                } else {
                    key = rawBaseCharacter(for: keyCode) ?? ""
                }
                if !key.isEmpty {
                    service.sendKey(key, shift: shift, ctrl: ctrl, alt: alt, command: command, to: device)
                }
            }
            return nil
            
        case .keyUp:
            return nil
            
        case .flagsChanged:
            service.optionKeyPressed = event.flags.contains(.maskAlternate)
            // Must pass through: consuming flagsChanged causes modifier state to get stuck in the OS.
            return Unmanaged.passUnretained(event)
            
        default:
            return nil
        }
    }
}

// MARK: DataPacket (MousePad)

fileprivate extension DataPacket {
    static let mousePadRequestPacketType = "kdeconnect.mousepad.request"
    static let mousePadKeyboardStatePacketType = "kdeconnect.mousepad.keyboardstate"
    /// Device → Mac: its pointer left through the entry edge (`releaseDeltax` / `releaseDeltay`)
    static let shareInputDevicesPacketType = "kdeconnect.shareinputdevices"
    /// Mac → device: the pointer crossed the screen edge (`exitEdge`, `deltax`, `deltay`)
    static let shareInputDevicesRequestPacketType = "kdeconnect.shareinputdevices.request"
    
    var isMousePadKeyboardStatePacket: Bool { type == DataPacket.mousePadKeyboardStatePacketType }
}
