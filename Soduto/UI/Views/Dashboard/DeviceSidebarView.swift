//
//  DeviceSidebarView.swift
//  Soduto
//
//  Created by Sannidhya Roy on 20/03/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import SwiftUI

struct DeviceSidebarView: View {
    @ObservedObject var model: DeviceDashboardModel

    @State private var infoDevice: IdentifiableDevice?
    @State private var deviceToUnpair: Device?

    var body: some View {
        List(selection: $model.selectedDeviceId) {
            if !model.devices.isEmpty {
                Section("My Devices") {
                    ForEach(model.devices) { device in
                        DeviceSidebarRow(device: device, batteryService: model.batteryService)
                            .tag(device.id)
                            .contextMenu {
                                Button("Device Info…") { infoDevice = IdentifiableDevice(device: device.device) }
                                Divider()
                                Button("Unpair…", role: .destructive) { deviceToUnpair = device.device }
                            }
                    }
                }
            }

            Section {
                ForEach(model.nearbyDevices, id: \.id) { device in
                    NearbyDeviceRow(device: device, onPair: { model.pair(device) })
                        .tag(device.id)
                        .contextMenu {
                            Button("Device Info…") { infoDevice = IdentifiableDevice(device: device) }
                        }
                }
            } header: {
                Text("Nearby")
            } footer: {
                if model.nearbyDevices.isEmpty {
                    Text("Devices running KDE Connect on this network appear here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Dashboard")
        .sheet(item: $infoDevice) { item in
            DeviceInfoView(device: item.device)
        }
        .confirmationDialog(
            deviceToUnpair.map { "Unpair \($0.name)?" } ?? "",
            isPresented: Binding(
                get: { deviceToUnpair != nil },
                set: { if !$0 { deviceToUnpair = nil } }
            ),
            titleVisibility: .visible,
            presenting: deviceToUnpair
        ) { device in
            Button("Unpair", role: .destructive) { model.unpair(device) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The device will need to be paired again before it can connect to this Mac.")
        }
    }
}

private struct DeviceSidebarRow: View {
    let device: DashboardDevice
    let batteryService: BatteryService?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: device.device.type.sfSymbolName)
                .font(.system(size: 18))
                .foregroundStyle(device.isReachable ? Color.secondary : Color(nsColor: .tertiaryLabelColor))
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.device.name)
                    .font(.body)
                    .foregroundStyle(device.isReachable ? .primary : .secondary)

                if let batteryImage = batteryService?.statusBarImage(for: device.device) {
                    Image(nsImage: batteryImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 13)
                } else if !device.isReachable {
                    Text("Disconnected")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            Circle()
                .fill(device.isReachable ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
                .help(device.isReachable ? "Connected" : "Disconnected")
        }
        .padding(.vertical, 2)
    }
}

/// A reachable device that isn't paired yet, with an inline Pair button
private struct NearbyDeviceRow: View {
    let device: Device
    let onPair: () -> Void

    private var isPairing: Bool {
        device.pairingStatus == .Requested || device.pairingStatus == .RequestedByPeer
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: device.type.sfSymbolName)
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
                .frame(width: 26)

            Text(device.name)
                .lineLimit(1)

            Spacer()

            if isPairing {
                ProgressView()
                    .controlSize(.small)
                    .help("Waiting for the device to accept")
            } else {
                Button("Pair", action: onPair)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }
}
