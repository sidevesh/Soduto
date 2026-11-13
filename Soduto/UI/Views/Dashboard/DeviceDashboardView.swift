//
//  DeviceDashboardView.swift
//  Soduto
//
//  Created by Sannidhya Roy on 20/03/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import SwiftUI

struct DeviceDashboardView: View {
    @ObservedObject var model: DeviceDashboardModel

    @State private var confirmingForceReconnect = false

    var body: some View {
        NavigationSplitView {
            DeviceSidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.discoverDevices()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Look for devices on the network")
                .keyboardShortcut("r", modifiers: .command)

                Menu {
                    Button("Force Reconnect…") { confirmingForceReconnect = true }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .help("More")
            }
        }
        .alert("Force Reconnect?", isPresented: $confirmingForceReconnect) {
            Button("Reconnect", role: .destructive) { model.forceReconnect() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All connections are closed, then Soduto looks for your devices again after about 10 seconds. Use this when a device shows as connected but nothing gets through. Try Refresh first.")
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let id = model.selectedDeviceId, let device = model.devices.first(where: { $0.id == id }) {
            DeviceDetailView(device: device, model: model)
        } else if let id = model.selectedDeviceId, let device = model.nearbyDevice(withId: id) {
            NearbyDeviceDetailView(device: device, onPair: { model.pair(device) })
        } else {
            ContentUnavailableView {
                Label("No Devices", systemImage: "iphone.slash")
            } description: {
                Text("Open KDE Connect on your phone or computer. Devices on the same network appear under Nearby, ready to pair.")
            } actions: {
                Button("Refresh") { model.discoverDevices() }
            }
        }
    }
}

/// Detail pane for a nearby device that isn't paired yet
private struct NearbyDeviceDetailView: View {
    let device: Device
    let onPair: () -> Void

    var body: some View {
        if device.pairingStatus == .Requested || device.pairingStatus == .RequestedByPeer {
            ContentUnavailableView {
                Label(device.name, systemImage: device.type.sfSymbolName)
            } description: {
                Text("Waiting for \(device.name) to accept. Check that the verification code on both devices matches.")
            } actions: {
                ProgressView()
            }
        } else {
            ContentUnavailableView {
                Label(device.name, systemImage: device.type.sfSymbolName)
            } description: {
                Text("Pair to share files, the clipboard, notifications and media with this device.")
            } actions: {
                Button("Pair", action: onPair)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
    }
}
