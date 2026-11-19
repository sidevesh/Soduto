//
//  CallViews.swift
//  Soduto
//
//  Copyright © 2026 Soduto. All rights reserved.
//

import AppKit
import SwiftUI

/// The windows for phone calls, laid out like macOS's own calling UI for iPhone calls: an incoming-call
/// banner in the top-right corner with Decline and Accept, and a small floating in-call window with the
/// caller, a timer, mute, keypad, audio route and end.
@MainActor
final class CallWindows {

    static let shared = CallWindows()

    private var incomingPanel: NSPanel?
    private var inCallPanel: NSPanel?

    // MARK: Incoming

    func showIncoming() {
        guard incomingPanel == nil else { return }
        let size = NSSize(width: 372, height: 84)
        let hosting = NSHostingView(rootView: IncomingCallView(manager: .shared))
        hosting.frame = NSRect(origin: .zero, size: size)

        let panel = Self.makePanel(size: size)
        panel.contentView = hosting
        panel.level = .statusBar

        // Slide in from the right edge, where notifications appear
        guard let screen = NSScreen.main else { return }
        let target = NSPoint(x: screen.visibleFrame.maxX - size.width - 12, y: screen.visibleFrame.maxY - size.height - 12)
        panel.setFrameOrigin(NSPoint(x: target.x + 40, y: target.y))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrameOrigin(target)
            panel.animator().alphaValue = 1
        }
        incomingPanel = panel
    }

    func hideIncoming() {
        guard let panel = incomingPanel else { return }
        incomingPanel = nil
        Self.fadeOut(panel)
    }

    // MARK: In call

    func showInCall() {
        if let panel = inCallPanel {
            panel.orderFrontRegardless()
            return
        }
        let controller = NSHostingController(rootView: InCallView(manager: .shared))
        controller.sizingOptions = [.preferredContentSize]
        let panel = Self.makePanel(size: NSSize(width: 300, height: 140))
        panel.contentViewController = controller
        panel.level = .floating
        panel.isMovableByWindowBackground = true

        if let screen = NSScreen.main {
            let frame = panel.frame
            panel.setFrameTopLeftPoint(NSPoint(x: screen.visibleFrame.maxX - frame.width - 12, y: screen.visibleFrame.maxY - 12))
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 1
        }
        inCallPanel = panel
    }

    func hideInCall() {
        guard let panel = inCallPanel else { return }
        inCallPanel = nil
        Self.fadeOut(panel)
    }

    // MARK: Helpers

    private static func makePanel(size: NSSize) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return panel
    }

    private static func fadeOut(_ panel: NSPanel) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }
}

// MARK: - Incoming call banner

private struct IncomingCallView: View {
    @ObservedObject var manager: CallManager

    var body: some View {
        HStack(spacing: 12) {
            CallerAvatar(name: manager.callerName, photo: manager.callerPhoto, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(callTitle(manager))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(incomingSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            CircleButton(symbol: "phone.down.fill", tint: .red, help: "Decline") { manager.decline() }
            CircleButton(symbol: "phone.fill", tint: .green, help: "Accept") { manager.accept() }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(CallSurface())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Incoming call from \(callTitle(manager))")
    }

    private var incomingSubtitle: String {
        if manager.callerName != nil, let number = manager.call?.number {
            return "\(number) · Phone"
        }
        return "Incoming call · Phone"
    }
}

// MARK: - In-call window

private struct InCallView: View {
    @ObservedObject var manager: CallManager
    @State private var showsKeypad = false
    @State private var dialed = ""

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                CallerAvatar(name: manager.callerName, photo: manager.callerPhoto, size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(showsKeypad && !dialed.isEmpty ? dialed : callTitle(manager))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.head)
                    status
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            if showsKeypad {
                Keypad { digit in
                    dialed.append(digit)
                    manager.sendDigit(digit)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }

            HStack(spacing: 18) {
                ToggleCircle(symbol: manager.call?.isMuted == true ? "mic.slash.fill" : "mic.fill",
                             label: "Mute", isOn: manager.call?.isMuted == true) { manager.toggleMute() }
                ToggleCircle(symbol: "circle.grid.3x3.fill", label: "Keypad", isOn: showsKeypad) {
                    withAnimation(.easeInOut(duration: 0.2)) { showsKeypad.toggle() }
                }
                .disabled(manager.call?.phase != .active)
                ToggleCircle(symbol: manager.call?.audioOnMac == false ? "smartphone" : "laptopcomputer",
                             label: manager.call?.audioOnMac == false ? "Phone" : "Mac", isOn: false) { manager.toggleAudioRoute() }
                    .help(manager.call?.audioOnMac == false ? "Audio on the phone: move it to this Mac" : "Audio on this Mac: move it to the phone")
                VStack(spacing: 4) {
                    CircleButton(symbol: "phone.down.fill", tint: .red, help: "End Call") { manager.end() }
                    Text("End").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .frame(width: 300)
        .modifier(CallSurface())
    }

    @ViewBuilder
    private var status: some View {
        switch manager.call?.phase {
        case .active:
            if let start = manager.call?.startedAt {
                TimelineView(.periodic(from: start, by: 1)) { context in
                    Text(Self.duration(from: start, to: context.date))
                }
            }
        case .outgoing:
            Text("Calling…")
        case .incoming:
            Text("Incoming call")
        case nil:
            Text("Call ended")
        }
    }

    private static func duration(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let rest = seconds % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }
}

// MARK: - Keypad

private struct Keypad: View {
    let onDigit: (String) -> Void

    private let keys: [(digit: String, letters: String)] = [
        ("1", ""), ("2", "ABC"), ("3", "DEF"),
        ("4", "GHI"), ("5", "JKL"), ("6", "MNO"),
        ("7", "PQRS"), ("8", "TUV"), ("9", "WXYZ"),
        ("*", ""), ("0", "+"), ("#", ""),
    ]

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(56), spacing: 14), count: 3), spacing: 10) {
            ForEach(keys, id: \.digit) { key in
                Button {
                    onDigit(key.digit)
                } label: {
                    VStack(spacing: 0) {
                        Text(key.digit).font(.system(size: 20, weight: .regular))
                        Text(key.letters).font(.system(size: 8, weight: .semibold)).tracking(1.5).opacity(key.letters.isEmpty ? 0 : 0.7)
                    }
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(Color.primary.opacity(0.1)))
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(key.digit)
            }
        }
    }
}

// MARK: - Pieces

/// A contact photo, or initials on grey like Contacts, or a person for an unknown caller
private struct CallerAvatar: View {
    let name: String?
    let photo: NSImage?
    let size: CGFloat

    var body: some View {
        Group {
            if let photo {
                Image(nsImage: photo).resizable().scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [Color(white: 0.66), Color(white: 0.5)], startPoint: .top, endPoint: .bottom)
                    if let initials {
                        Text(initials).font(.system(size: size * 0.4, weight: .medium)).foregroundStyle(.white)
                    } else {
                        Image(systemName: "person.fill").font(.system(size: size * 0.45)).foregroundStyle(.white)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    private var initials: String? {
        guard let name, name.contains(where: \.isLetter) else { return nil }
        let words = name.split(separator: " ").filter { $0.first?.isLetter == true }
        let letters = words.prefix(2).compactMap(\.first).map(String.init)
        return letters.isEmpty ? nil : letters.joined().uppercased()
    }
}

/// The round coloured buttons of macOS's call UI (green accept, red decline / end)
private struct CircleButton: View {
    let symbol: String
    let tint: Color
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Circle().fill(tint))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A round control with its label underneath; filled when on
private struct ToggleCircle: View {
    let symbol: String
    let label: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isOn ? Color(nsColor: .windowBackgroundColor) : .primary)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(isOn ? Color.primary : Color.primary.opacity(0.12)))
                Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Liquid Glass on macOS 26 and later, the system material before that
private struct CallSurface: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        } else {
            content
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        }
    }
}

@MainActor
private func callTitle(_ manager: CallManager) -> String {
    manager.callerName ?? manager.call?.number ?? "Unknown Caller"
}
