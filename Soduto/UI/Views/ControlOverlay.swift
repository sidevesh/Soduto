//
//  ControlOverlay.swift
//  Soduto
//
//  Copyright © 2026 Soduto. All rights reserved.
//

import Cocoa
import SwiftUI

/// The pill shown at the top of the screen while this Mac's keyboard and mouse control a device,
/// in the spirit of Screen Sharing / Universal Control: device icon, "Controlling <name>" and how to
/// get back. After a few seconds it shrinks to just the icon and name so it stays out of the way.
final class ControlOverlay {

    fileprivate final class Model: ObservableObject {
        let deviceName: String
        let symbolName: String
        let hint: String
        let note: String?
        @Published var isCompact = false

        init(deviceName: String, symbolName: String, hint: String, note: String?) {
            self.deviceName = deviceName
            self.symbolName = symbolName
            self.hint = hint
            self.note = note
        }
    }

    private var panel: NSPanel?
    private var collapseWorkItem: DispatchWorkItem?

    /// Panel size; the pill is centred at its top and the transparent rest ignores the mouse
    private static let panelSize = NSSize(width: 560, height: 96)

    func show(deviceName: String, symbolName: String, hint: String, note: String? = nil) {
        hide(animated: false)

        let model = Model(deviceName: deviceName, symbolName: symbolName, hint: hint, note: note)
        let hosting = NSHostingView(rootView: ControlOverlayView(model: model))
        hosting.frame = NSRect(origin: .zero, size: Self.panelSize)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false  // the pill draws its own shadow
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = hosting

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - Self.panelSize.width / 2,
                                         y: frame.maxY - Self.panelSize.height - 6))
        }

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 1
        }
        self.panel = panel

        let collapse = DispatchWorkItem { [weak model] in
            withAnimation(.easeInOut(duration: 0.35)) { model?.isCompact = true }
        }
        collapseWorkItem = collapse
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: collapse)
    }

    func hide(animated: Bool = true) {
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
        guard let panel else { return }
        self.panel = nil
        guard animated else {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    // MARK: - View

    fileprivate struct ControlOverlayView: View {
        @ObservedObject var model: Model

        var body: some View {
            VStack {
                pill
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }

        private var pill: some View {
            HStack(spacing: model.isCompact ? 8 : 12) {
                Image(systemName: model.symbolName)
                    .font(.system(size: model.isCompact ? 15 : 22, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: model.isCompact ? 18 : 26)

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.isCompact ? model.deviceName : "Controlling \(model.deviceName)")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if !model.isCompact {
                        Text(model.hint)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if let note = model.note {
                            Text(note)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(.horizontal, model.isCompact ? 14 : 18)
            .padding(.vertical, model.isCompact ? 7 : 11)
            .modifier(PillBackground())
            .padding(.top, 4)
            .accessibilityElement(children: .combine)
        }
    }

    /// Liquid Glass on macOS 26 and later, the system material before that
    fileprivate struct PillBackground: ViewModifier {
        func body(content: Content) -> some View {
            if #available(macOS 26.0, *) {
                content.glassEffect(.regular, in: Capsule())
            } else {
                content
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
            }
        }
    }
}
