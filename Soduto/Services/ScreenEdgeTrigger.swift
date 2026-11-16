//
//  ScreenEdgeTrigger.swift
//  Soduto
//
//  Copyright © 2026 Soduto. All rights reserved.
//

import Cocoa

/// The side of this Mac's main display that a remote device sits beyond.
public enum ScreenEdge: String, CaseIterable, Identifiable {
    case left, right, top, bottom

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .left: return "Left"
        case .right: return "Right"
        case .top: return "Top"
        case .bottom: return "Bottom"
        }
    }

    /// Qt::Edge value used by `kdeconnect.shareinputdevices.request` (`exitEdge`)
    var qtEdge: Int {
        switch self {
        case .top: return 0x1
        case .left: return 0x2
        case .right: return 0x4
        case .bottom: return 0x8
        }
    }
}

/// Detects the pointer being pushed past one edge of the main display (the one with the menu bar),
/// the gesture that hands the keyboard and mouse to a device sitting beyond that edge.
///
/// Cost: one passive mouse-moved monitor (no event tap, no polling, no permission needed) doing a
/// coordinate comparison per mouse move. It only runs while edge control is on and its device is
/// connected. A deliberate push is required (`requiredPush` points of movement into the edge within
/// `pushWindow` seconds) so brushing the edge, dragging something to it, or reaching for a hot
/// corner (`cornerMargin`) never triggers it.
final class ScreenEdgeTrigger {

    /// Called on the main thread with the edge and the pointer's position along it, in points from the
    /// top (left/right edges) or from the left (top/bottom edges) of the main display.
    var onTrigger: ((ScreenEdge, CGFloat) -> Void)?

    private(set) var edge: ScreenEdge?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    private var pushDistance: CGFloat = 0
    private var lastPushTime: TimeInterval = 0
    /// False after triggering or after the pointer returns from the device, until the pointer leaves the edge
    private var isArmed = true

    static let requiredPush: CGFloat = 80
    static let pushWindow: TimeInterval = 0.6
    static let cornerMargin: CGFloat = 24

    var isRunning: Bool { globalMonitor != nil }

    func start(edge: ScreenEdge) {
        if isRunning && self.edge == edge { return }
        stop()
        self.edge = edge
        pushDistance = 0
        isArmed = true
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        edge = nil
        pushDistance = 0
    }

    /// Requires the pointer to move off the edge before the next push counts
    /// (used right after control returns from the device, with the pointer placed at the edge).
    func disarmUntilPointerLeavesEdge() {
        isArmed = false
        pushDistance = 0
    }

    /// The main display's frame in AppKit coordinates (origin bottom-left)
    static var mainScreenFrame: NSRect? {
        NSScreen.screens.first?.frame
    }

    private func handle(_ event: NSEvent) {
        guard let edge, let frame = Self.mainScreenFrame else { return }
        let location = NSEvent.mouseLocation

        let atEdge: Bool
        let push: CGFloat        // movement into the edge for this event
        let along: CGFloat       // position along the edge, from top or left
        let alongLength: CGFloat
        switch edge {
        case .left:
            atEdge = location.x <= frame.minX + 1
            push = -event.deltaX
            along = frame.maxY - location.y
            alongLength = frame.height
        case .right:
            atEdge = location.x >= frame.maxX - 1
            push = event.deltaX
            along = frame.maxY - location.y
            alongLength = frame.height
        case .top:
            atEdge = location.y >= frame.maxY - 1
            push = -event.deltaY     // NSEvent deltaY is positive downwards
            along = location.x - frame.minX
            alongLength = frame.width
        case .bottom:
            atEdge = location.y <= frame.minY + 1
            push = event.deltaY
            along = location.x - frame.minX
            alongLength = frame.width
        }

        guard atEdge else {
            pushDistance = 0
            isArmed = true
            return
        }
        guard isArmed,
              NSEvent.pressedMouseButtons == 0,
              along > Self.cornerMargin, along < alongLength - Self.cornerMargin,
              push > 0 else { return }

        let now = ProcessInfo.processInfo.systemUptime
        if now - lastPushTime > Self.pushWindow { pushDistance = 0 }
        lastPushTime = now
        pushDistance += push

        if pushDistance >= Self.requiredPush {
            pushDistance = 0
            isArmed = false
            onTrigger?(edge, along)
        }
    }
}
