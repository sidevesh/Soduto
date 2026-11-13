//
//  DeviceDashboardModel.swift
//  Soduto
//
//  Created by Sannidhya Roy on 20/03/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import Foundation
import Combine

/// Aggregated snapshot of a single paired device for the dashboard.
struct DashboardDevice: Identifiable {
    let id: Device.Id
    let device: Device
    var isReachable: Bool
    /// Stamped when this device last transitioned from reachable → unreachable
    var lastSeenDate: Date?
    /// Remote players; frozen at last-known state when unreachable
    var players: [PlayerRemote]
    /// Battery status: used as an invalidation key so SwiftUI re-renders when it changes
    /// Views use `batteryService.statusBarImage()` for the actual rendered image
    var batteryStatus: BatteryService.BatteryStatus?
    /// Connectivity status: used as an invalidation key so SwiftUI re-renders when it changes
    /// Views use `connectivityReportService.statusBarImage()` for the actual rendered image
    var connectivityStatus: [ConnectivityReportService.ConnectivityStatus]?
}

/// Central observable model for the Device Dashboard.
///
/// Aggregates state from `DeviceDataSource`, `MediaPlayerService`, `BatteryService`,
/// and `ConnectivityReportService` into a unified list of `DashboardDevice` values. Views observe
/// this model and call its command methods, they never touch services directly.
@MainActor
final class DeviceDashboardModel: ObservableObject {
    
    @Published private(set) var devices: [DashboardDevice] = []
    /// Reachable devices that aren't paired yet, offered for pairing in the sidebar's Nearby section
    @Published private(set) var nearbyDevices: [Device] = []
    @Published var selectedDeviceId: Device.Id?
    
    private let deviceDataSource: DeviceDataSource
    private weak var deviceManager: DeviceManager?
    let mediaPlayerService: MediaPlayerService?
    let batteryService: BatteryService?
    let connectivityReportService: ConnectivityReportService?
    
    private var cancellables: Set<AnyCancellable> = []
    /// Stamped when a device transitions from reachable → unreachable. Session-only.
    private var lastSeenDates: [Device.Id: Date] = [:]
    /// Last-known players before service cleared them on disconnect.
    private var cachedPlayers: [Device.Id: [PlayerRemote]] = [:]
    
    init(deviceDataSource: DeviceDataSource,
         deviceManager: DeviceManager?,
         mediaPlayerService: MediaPlayerService?,
         batteryService: BatteryService?,
         connectivityReportService: ConnectivityReportService?) {
        self.deviceDataSource = deviceDataSource
        self.deviceManager = deviceManager
        self.mediaPlayerService = mediaPlayerService
        self.batteryService = batteryService
        self.connectivityReportService = connectivityReportService
        
        // Merge all service-change signals and debounce so rapid-fire packets
        // (battery every 3-8s, connectivity, player list) coalesce into a single
        // rebuildDevices() call instead of hammering the SwiftUI view tree.
        let serviceChanges: [AnyPublisher<Void, Never>] = [
            mediaPlayerService?.$players.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            batteryService?.$statuses.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            connectivityReportService?.$statuses.dropFirst().map { _ in () }.eraseToAnyPublisher()
        ].compactMap { $0 }
        
        Publishers.MergeMany(serviceChanges)
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.rebuildDevices() }
            .store(in: &cancellables)
        
        // Use .scan to observe (previous, new) pairs so we can capture last-known
        // player state at the exact moment the service clears it on disconnect.
        // This fires synchronously on the main thread when @Published changes.
        mediaPlayerService?.$players
            .scan(([Device.Id: [PlayerRemote]](), [Device.Id: [PlayerRemote]]())) { ($0.1, $1) }
            .sink { [weak self] old, new in
                guard let self else { return }
                for id in old.keys where new[id] == nil || new[id]!.isEmpty {
                    if let players = old[id], !players.isEmpty {
                        self.cachedPlayers[id] = players
                    }
                }
            }
            .store(in: &cancellables)
        
        rebuildDevices()
    }
    
    /// Called by `StatusBarMenuController` whenever device connectivity or pairing state changes.
    func refreshDeviceList() {
        rebuildDevices()
    }
    
    // MARK: - Device Management
    
    /// The nearby (unpaired) device with this id, if any
    func nearbyDevice(withId id: Device.Id) -> Device? {
        nearbyDevices.first { $0.id == id }
    }
    
    /// Announces this Mac on the network so devices that missed it connect (⌘R)
    func discoverDevices() {
        NotificationCenter.default.post(name: ConnectionProvider.broadcastAnnouncementNotification, object: nil)
        rebuildDevices()
    }
    
    /// Closes every connection, waits for the teardown, then rediscovers devices.
    /// Last resort for connections that look alive but no longer carry packets.
    func forceReconnect() {
        guard let deviceManager else { return }
        deviceManager.closeAllConnections()
        // Wait for the asynchronous closes so new connections don't race the old ones
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            NetworkUtils.pingLocalNetwork()  // fills the ARP table so directed announcements reach devices
            NotificationCenter.default.post(name: ConnectionProvider.broadcastAnnouncementNotification, object: nil)
            self?.rebuildDevices()
        }
    }
    
    func pair(_ device: Device) {
        device.requestPairing()
        PairingWindowController.showOutgoingRequest(for: device)
        rebuildDevices()
    }
    
    func unpair(_ device: Device) {
        device.unpair()
        rebuildDevices()
    }
    
    // MARK: - Media Player Commands
    
    func playPause(for player: PlayerRemote) {
        mediaPlayerService?.controlPlayPause(for: player)
    }
    
    func stop(for player: PlayerRemote) {
        mediaPlayerService?.controlStop(for: player)
    }
    
    func next(for player: PlayerRemote) {
        mediaPlayerService?.controlNext(for: player)
    }
    
    func previous(for player: PlayerRemote) {
        mediaPlayerService?.controlPrevious(for: player)
    }
    
    func setVolume(_ volume: Int, for player: PlayerRemote) {
        mediaPlayerService?.controlSetVolume(for: player, volume: volume)
    }
    
    func setPosition(_ positionMs: Int, for player: PlayerRemote) {
        mediaPlayerService?.controlSetPosition(for: player, positionMs: positionMs)
    }
    
    func seek(_ seconds: Int, for player: PlayerRemote) {
        mediaPlayerService?.controlSeek(for: player, offsetUs: seconds * 1_000_000)
    }
    
    func setLoopStatus(_ loopStatus: String, for player: PlayerRemote) {
        mediaPlayerService?.controlSetLoopStatus(for: player, loopStatus: loopStatus)
    }
    
    func setShuffle(_ shuffle: Bool, for player: PlayerRemote) {
        mediaPlayerService?.controlSetShuffle(for: player, shuffle: shuffle)
    }
    
    // MARK: - Private
    
    private func rebuildDevices() {
        // Defer to next runloop to avoid "Publishing changes from within view updates" error
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Snapshot previous reachability so we can detect transitions below
            let previousReachable = Dictionary(uniqueKeysWithValues: self.devices.map { ($0.id, $0.isReachable) })
            
            // Include both tracked (paired) and config-only (unavailable) devices so the
            // sidebar always shows all paired devices regardless of connectivity state
            let allPaired = self.deviceDataSource.pairedDevices + self.deviceDataSource.unavailableDevices
            let reachableIds = Set(self.deviceDataSource.pairedRechableDevices.map(\.id))
            
            // Stamp last-seen whenever a device transitions reachable → unreachable
            let now = Date()
            for device in allPaired {
                let wasReachable = previousReachable[device.id] ?? false
                let isNowReachable = reachableIds.contains(device.id)
                if wasReachable && !isNowReachable {
                    self.lastSeenDates[device.id] = now
                }
            }
            
            self.devices = allPaired.map { device in
                let isNowReachable = reachableIds.contains(device.id)
                // Use live service data when reachable; fall back to cache when offline
                // so the UI shows a frozen but meaningful last-known state.
                let players = isNowReachable
                    ? (self.mediaPlayerService?.players[device.id] ?? [])
                    : (self.cachedPlayers[device.id] ?? [])
                return DashboardDevice(
                    id: device.id,
                    device: device,
                    isReachable: isNowReachable,
                    lastSeenDate: self.lastSeenDates[device.id],
                    players: players,
                    batteryStatus: self.batteryService?.statuses[device.id],
                    connectivityStatus: self.connectivityReportService?.statuses[device.id]
                )
            }
            .sorted { $0.device.name < $1.device.name }
            
            let pairedIds = Set(allPaired.map(\.id))
            self.nearbyDevices = self.deviceDataSource.unpairedDevices
                .filter { !pairedIds.contains($0.id) }
                .sorted { $0.name < $1.name }
            
            // Auto-select the first paired device if nothing is selected or the selection is gone
            let selectionExists = self.devices.contains(where: { $0.id == self.selectedDeviceId })
                || self.nearbyDevices.contains(where: { $0.id == self.selectedDeviceId })
            if self.selectedDeviceId == nil || !selectionExists {
                self.selectedDeviceId = self.devices.first?.id ?? self.nearbyDevices.first?.id
            }
        }
    }
}
