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
/// Implements the outgoing side of the `kdeconnect.mousepad` protocol. When capturing is
/// active, all Mac keyboard and mouse events are intercepted via a CGEvent tap and forwarded
/// as `kdeconnect.mousepad.request` packets to the paired target device. The Mac cursor is
/// hidden and locked to the screen center so the physical pointer stays out of the way, and a
/// floating overlay shows which device is being controlled and how to exit.
///
/// Start it with the device's **Control Device** menu action; press **Option+Escape** to exit.
///
/// Requires Accessibility permissions (System Settings › Privacy & Security › Accessibility).
public class RemoteControlService: OutgoingService, ObservableObject {
    
    // MARK: ServiceBase
    
    public var userDefaults: UserDefaults = .standard
    public let outgoingPreferenceKey = AppDefaultsStore.Preferences.Services.RemoteControl.outgoingKey
    
    // MARK: Properties
    
    public static let serviceId: Service.Id = "com.soduto.services.remotecontrol"
    
    public let incomingCapabilities = Set<Service.Capability>([
        DataPacket.mousePadKeyboardStatePacketType
    ])
    public var outgoingCapabilities: Set<Service.Capability> {
        outgoingEnabled ? [DataPacket.mousePadRequestPacketType] : []
    }
    
    @Published public private(set) var isCapturing = false
    
    /// Last `kdeconnect.mousepad.keyboardstate` reported per device: whether it can receive typed keys
    /// (KDE Connect Android needs its "Keyboard receiver (via accessibility)" or Remote Keyboard enabled).
    private var remoteKeyboardStates: [Device.Id: Bool] = [:]
    
    /// Overlay shown while capturing, naming the target device and the exit shortcut.
    private var hudPanel: NSPanel?
    
    private var targetDevice: Device?
    private var eventTap: CFMachPort?
    private var eventRunLoopSource: CFRunLoopSource?
    private var optionKeyPressed = false
    private var isDragging = false
    private var originalMouseLocation: NSPoint?
    private var invisibleCursor: NSCursor?
    private var escapeMonitor: Any?
    
    /// Exposes the connected device type to the CGEvent tap callback (which has no `self`).
    var targetDeviceType: DeviceType? { targetDevice?.type }
    
    // Scroll/swipe accumulation while capturing
    private var lockScrollAccumDx: Double = 0
    private var lockScrollAccumDy: Double = 0
    private var lockScrollStart: Date?
    
    
    // MARK: Service
    
    public func handleDataPacket(_ dataPacket: DataPacket, fromDevice device: Device, onConnection connection: Connection) -> Bool {
        guard dataPacket.isMousePadKeyboardStatePacket else { return false }
        if let state = dataPacket.body["state"] as? NSNumber {
            remoteKeyboardStates[device.id] = state.boolValue
        }
        return true
    }
    
    public func setup(for device: Device) {}
    
    public func cleanup(for device: Device) {
        remoteKeyboardStates.removeValue(forKey: device.id)
        if targetDevice?.id == device.id {
            stopCapturing()
        }
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
            startCapturing(for: device)
        case ActionId.stopInputCapturing.rawValue:
            stopCapturing()
        default:
            Logger.services.notice("Unknown action id: \(id, privacy: .public)")
        }
    }
    
    
    // MARK: Capturing
    
    /// Shows an accessibility permission alert if not yet granted. System notification alone is too subtle.
    func checkAccessibilityForLock() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        guard !AXIsProcessTrustedWithOptions(options) else { return }
        
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Accessibility Permissions Required"
            alert.informativeText = "Control Device captures all keyboard and mouse events to control the remote device. Soduto needs Accessibility permissions to do this.\n\nGrant access in System Settings › Privacy & Security › Accessibility, then choose Control Device again."
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn {
                if #available(macOS 13.0, *) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                } else {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/PreferencePanes/Security.prefPane"))
                }
            }
        }
    }
    
    /// Accessibility is reported as granted but the event tap still can't be created. This happens when the
    /// permission entry belongs to an older build of the app (e.g. after rebuilding or reinstalling).
    private func showEventTapFailureAlert() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Couldn't Start Controlling the Device"
            alert.informativeText = "macOS didn't allow Soduto to capture keyboard and mouse input, even though Accessibility access looks granted. This usually means the permission belongs to an older build of Soduto.\n\nRemove Soduto from System Settings › Privacy & Security › Accessibility, add it again, then choose Control Device again."
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
        }
    }
    
    func startCapturing(for device: Device) {
        guard !isCapturing, device.pairingStatus == .Paired else { return }
        
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        guard AXIsProcessTrustedWithOptions(options) else {
            Logger.services.notice("Accessibility permissions not granted for remote control; prompting user...")
            checkAccessibilityForLock()  // reuse the same visible alert
            return
        }
        
        Logger.services.info("Starting input capture for device: \(device.name, privacy: .public)")
        targetDevice = device
        isCapturing = true
        isDragging = false
        
        // Without the tap nothing is forwarded and Option+Escape can't be caught, so never hide the cursor then
        guard setupEventTap() else {
            isCapturing = false
            targetDevice = nil
            showEventTapFailureAlert()
            return
        }
        setupEscapeMonitor()
        hideCursorAndCenterOnScreen()
        showHUD(for: device)
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
        
        removeEventTap()
        removeEscapeMonitor()
        showCursorAndRestorePosition()
        hideHUD()
        
        Logger.services.info("Input capture stopped")
    }
    
    
    // MARK: Overlay
    
    private func showHUD(for device: Device) {
        hideHUD()
        
        var lines: [(text: String, font: NSFont)] = [
            ("Controlling Remote Device", .boldSystemFont(ofSize: 16)),
            (device.name, .systemFont(ofSize: 14)),
            ("Press ⌥ Option + Esc to stop", .systemFont(ofSize: 12))
        ]
        if remoteKeyboardStates[device.id] == false {
            lines.append(("Typing needs the keyboard receiver enabled on the device", .systemFont(ofSize: 11)))
        }
        
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 24, bottom: 16, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for line in lines {
            let label = NSTextField(labelWithString: line.text)
            label.font = line.font
            label.textColor = .white
            label.alignment = .center
            stack.addArrangedSubview(label)
        }
        
        let effectView = NSVisualEffectView()
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 12
        effectView.layer?.masksToBounds = true
        effectView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: effectView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effectView.trailingAnchor)
        ])
        
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .vibrantDark)
        panel.contentView = effectView
        panel.setContentSize(stack.fittingSize)
        
        // Top-center of the screen the cursor is locked to
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 40))
        }
        
        panel.orderFrontRegardless()
        hudPanel = panel
    }
    
    private func hideHUD() {
        guard let panel = hudPanel else { return }
        // Order out instead of close(): closing a borderless panel we still reference can over-release it
        panel.orderOut(nil)
        panel.contentView = nil
        hudPanel = nil
    }
    
    
    // MARK: Cursor management
    
    private func hideCursorAndCenterOnScreen() {
        originalMouseLocation = NSEvent.mouseLocation
        
        let blankImage = NSImage(size: NSSize(width: 1, height: 1))
        invisibleCursor = NSCursor(image: blankImage, hotSpot: .zero)
        NSCursor.hide()
        invisibleCursor?.push()
        
        if let screen = NSScreen.main {
            CGWarpMouseCursorPosition(CGPoint(x: screen.frame.midX, y: screen.frame.midY))
        }
    }
    
    private func showCursorAndRestorePosition() {
        if invisibleCursor != nil {
            invisibleCursor?.pop()
            invisibleCursor = nil
            NSCursor.unhide()
        }
        if let pos = originalMouseLocation {
            CGWarpMouseCursorPosition(CGPoint(x: pos.x, y: pos.y))
            originalMouseLocation = nil
        }
    }
    
    
    // MARK: Event tap
    
    /// Returns false when the tap can't be created (usually missing or stale Accessibility permission).
    private func setupEventTap() -> Bool {
        let eventMask: CGEventMask = [
            CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged,
            .scrollWheel, .keyDown, .keyUp, .flagsChanged
        ].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
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
        guard service.isCapturing, let device = service.targetDevice else {
            return Unmanaged.passUnretained(event)
        }
        
        // Re-enable tap if macOS auto-disabled it (slow callbacks).
        if let tap = service.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        
        let eventType = CGEventType(rawValue: type.rawValue) ?? .null
        
        switch eventType {
            
        // MARK: Mouse movement
        case .mouseMoved:
            let dx = event.getDoubleValueField(.mouseEventDeltaX)
            let dy = event.getDoubleValueField(.mouseEventDeltaY)
            if abs(dx) > 0.5 || abs(dy) > 0.5 {
                service.sendMouseMove(dx: CGFloat(dx), dy: CGFloat(dy), to: device)
            }
            if let screen = NSScreen.main {
                CGWarpMouseCursorPosition(CGPoint(x: screen.frame.midX, y: screen.frame.midY))
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
                    if let nsEvent = NSEvent(cgEvent: event) {
                        key = (ctrl ? nsEvent.charactersIgnoringModifiers : nsEvent.characters) ?? ""
                    } else { key = "" }
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
    
    var isMousePadKeyboardStatePacket: Bool { type == DataPacket.mousePadKeyboardStatePacketType }
}
