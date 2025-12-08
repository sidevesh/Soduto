//
//  NotificationsService.swift
//  Soduto
//
//  Created by Giedrius Stanevičius on 2016-11-26.
//  Copyright © 2016 Soduto. All rights reserved.
//

import Foundation
import Cocoa
import CleanroomLogger
import MediaPlayer
import UserNotifications
import CommonCrypto

// MARK: - Local Media Controller

/// Handles local media player management and communication with remote devices
class LocalMediaController: NSObject {
    /// Local media players that can be controlled by remote devices
    private var localPlayers: [String: LocalPlayer] = [:]
    /// Track connected devices for broadcasting updates
    private var connectedDevices: [String: Device] = [:]
    
    // MARK: Initialization
    
    override init() {
        super.init()
        setupLocalPlayers()
        
        // Clean up old cache files on startup
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.cleanupOldCacheFiles()
        }
    }
    
    // MARK: - Public Interface
    
    func addConnectedDevice(_ device: Device) {
        connectedDevices[device.id] = device
    }
    
    func removeConnectedDevice(_ device: Device) {
        connectedDevices.removeValue(forKey: device.id)
    }
    
    func getLocalPlayer(identity: String) -> LocalPlayer? {
        return localPlayers[identity]
    }
    
    func getAllLocalPlayers() -> [String: LocalPlayer] {
        return localPlayers
    }
    
    // MARK: - Local Player Management
    
    private func setupLocalPlayers() {
        // Create MediaRemoteAdapter-based players for real macOS integration
        setupMediaRemoteBasedLocalPlayers(initialIdentity: "Unknown app")
        
        // Setup callbacks for state change broadcasting  
        // Using LocalMediaController for local media control
        setupMediaRemoteAdapterCallbacks()
    }
    
    private func setupMediaRemoteBasedLocalPlayers(initialIdentity: String) {
        // Create MediaRemoteAdapter player that interfaces with the perl script
        // Start with the provided identity that will be updated based on actual playing app
        let mediaRemoteAdapterPlayer = MediaRemoteBasedLocalPlayer(identity: initialIdentity)
        mediaRemoteAdapterPlayer.parentController = self // Set parent reference for identity updates
        localPlayers[mediaRemoteAdapterPlayer.identity] = mediaRemoteAdapterPlayer
    }
    

    
    /// Setup state change callbacks for MediaRemoteAdapter players to broadcast updates
    private func setupMediaRemoteAdapterCallbacks() {
        for (_, player) in localPlayers {
            player.onStateChanged = { [weak self] in
                self?.broadcastPlayerUpdate(player)
            }
        }
    }
    
    /// Update a local player's identity when the active app changes
    func updateLocalPlayerIdentity(from oldIdentity: String, to newIdentity: String, player: LocalPlayer) {
        // Remove from old identity
        localPlayers.removeValue(forKey: oldIdentity)
        
        // Add with new identity
        localPlayers[newIdentity] = player
        
        Log.info?.message("MPRIS::Player identity updated: '\(oldIdentity)' → '\(newIdentity)'")
        
        // Broadcast updated player list to all connected devices
        for (_, device) in connectedDevices {
            sendPlayerList(to: device)
        }
    }
    
    /// Debug method to print current state of all local players
    private func logPlayerStates() {
        Log.info?.message("MPRIS::📊 Current Local Player States:")
        for (identity, player) in localPlayers {
            let state = player.isPlaying ? "▶️ Playing" : "⏸️ Paused"
            let track = "\(player.artist) - \(player.title)".isEmpty ? "No track" : "\(player.artist) - \(player.title)"
            let position = "\(player.position)/\(player.length)s"
            Log.info?.message("MPRIS::\(identity): \(state) | \(track) | \(position) | Vol:\(player.volume)%")
        }
        Log.info?.message("MPRIS::📱 Connected devices: \(connectedDevices.count)")
        for (deviceId, device) in connectedDevices {
            Log.info?.message("MPRIS::\(device.name) (\(deviceId))")
        }
    }
    
    func handlePlayerCommand(action: String, player: LocalPlayer, fromDevice device: Device) {
        Log.info?.message("MPRIS::🎮 Remote control: \(device.name) sent '\(action)' command to \(player.identity)")
        
        let oldState = player.isPlaying
        let oldTrack = "\(player.artist) - \(player.title)"
        
        switch action {
        case "Play":
            player.play()
        case "Pause":
            player.pause()
        case "PlayPause":
            player.playPause()
        case "Next":
            player.next()
        case "Previous":
            player.previous()
        case "Stop":
            player.stop()
        default:
            Log.warning?.message("MPRIS::❌ Unknown action: \(action)")
            return
        }
        
        // Log the state change
        let newState = player.isPlaying
        let newTrack = "\(player.artist) - \(player.title)"
        
        if oldState != newState {
            let stateDesc = newState ? "▶️ Playing" : "⏸️ Paused"
            Log.info?.message("MPRIS::State changed to: \(stateDesc)")
        }
        
        if oldTrack != newTrack && action == "Next" || action == "Previous" {
            Log.info?.message("MPRIS::Track changed to: \(newTrack)")
        }
        
        // Send updated player state
        sendPlayerUpdate(player, to: device)
    }
    
    func sendPlayerList(to device: Device) {
        let playerIdentities = Array(localPlayers.keys).sorted() // Sort for consistency
        
        // Create the packet body exactly like GSConnect does
        let packet = DataPacket(type: DataPacket.mprisPacketType, body: [
            "playerList": playerIdentities as AnyObject,
            "supportAlbumArtPayload": true as AnyObject
        ])
        
        device.send(packet)
        
        // Also send initial state for each player (like GSConnect does)
        // Send updates after a small delay to ensure the remote device processes the player list first
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            for (_, player) in self.localPlayers {
                self.sendPlayerUpdate(player, to: device)
            }
        }
    }
    
    func sendPlayerUpdate(_ player: LocalPlayer, to device: Device) {
        // Use the comprehensive update method for better GSConnect compatibility
        sendComprehensivePlayerUpdate(player, to: device)
    }
    
    private func broadcastPlayerUpdate(_ player: LocalPlayer) {
        // Send updates to all connected devices
        for (_, device) in connectedDevices {
            sendPlayerUpdate(player, to: device)
        }
    }
    
    /// Send a comprehensive player update that matches GSConnect format
    private func sendComprehensivePlayerUpdate(_ player: LocalPlayer, to device: Device) {
        // Create a packet that matches the GSConnect format exactly
        var body: [String: AnyObject] = [
            "player": player.identity as AnyObject,
            "isPlaying": player.isPlaying as AnyObject,
            "pos": (player.position * 1000) as AnyObject, // Convert seconds to milliseconds
            "canPause": player.canPause as AnyObject,
            "canPlay": player.canPlay as AnyObject,
            "canGoNext": player.canGoNext as AnyObject,
            "canGoPrevious": player.canGoPrevious as AnyObject,
            "canSeek": player.canSeek as AnyObject,
            "volume": player.volume as AnyObject,
            "loopStatus": player.loopStatus as AnyObject,
            "shuffle": player.shuffle as AnyObject
        ]
        
        // Add metadata if available
        if !player.artist.isEmpty {
            body["artist"] = player.artist as AnyObject
        }
        
        if !player.title.isEmpty {
            body["title"] = player.title as AnyObject
        }
        
        if !player.album.isEmpty {
            body["album"] = player.album as AnyObject
        }
        
        if player.length > 0 {
            body["length"] = (player.length * 1000) as AnyObject // Convert seconds to milliseconds
        }
        
        // Create nowPlaying string like GSConnect does
        var nowPlaying = ""
        if !player.artist.isEmpty && !player.title.isEmpty {
            nowPlaying = "\(player.artist) - \(player.title)"
        } else if !player.artist.isEmpty {
            nowPlaying = player.artist
        } else if !player.title.isEmpty {
            nowPlaying = player.title
        } else {
            nowPlaying = "Unknown"
        }
        body["nowPlaying"] = nowPlaying as AnyObject
        
        // Add album art URL if available
        if !player.albumArtUrl.isEmpty {
            body["albumArtUrl"] = player.albumArtUrl as AnyObject
        } else {
            body["albumArtUrl"] = "" as AnyObject
        }
        
        let packet = DataPacket(type: DataPacket.mprisPacketType, body: body)
        
        device.send(packet)
    }
    
    // MARK: - Cache Management
    
    private func cleanupOldCacheFiles() {
        let cacheDirectory = getCacheDirectory()
        
        // Check if cache directory exists, if not, nothing to clean up
        guard FileManager.default.fileExists(atPath: cacheDirectory.path) else {
            return
        }
        
        do {
            let contents = try FileManager.default.contentsOfDirectory(at: cacheDirectory, 
                                                                      includingPropertiesForKeys: [.contentModificationDateKey], 
                                                                      options: [])
            
            let cutoffDate = Date().addingTimeInterval(-7 * 24 * 60 * 60) // 7 days ago
            
            for fileURL in contents {
                if let modificationDate = try fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   modificationDate < cutoffDate {
                    try FileManager.default.removeItem(at: fileURL)
                }
            }
        } catch {
            Log.error?.message("MPRIS::Failed to cleanup old cache files: \(error)")
        }
    }
    
    // Helper function needed for cache management
    private func getCacheDirectory() -> URL {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documentsPath.appendingPathComponent("SodutoCache").appendingPathComponent("albumart")
    }
}

/// MPRIS (Media Player Remote Interfacing Specification) Service
/// 
/// This service allows for remote control of media players on connected devices.
/// 
/// It receives packets with type "kdeconnect.mpris" containing:
/// - playerList (array): list of available media players on the remote device
/// - player (string): the player that sent the update
/// - pos (int): current position in the track (in seconds)
/// - isPlaying (boolean): whether the player is currently playing
/// - canPause, canPlay, canGoNext, canGoPrevious (boolean): player capabilities
/// - albumArtUrl (string): URL to album art image
/// - length (int): track length in seconds
/// - artist, title, album (string): track metadata
/// - volume (int): player volume percentage (0-100)
/// 
/// It sends packets with type "kdeconnect.mpris.request" containing:
/// - requestPlayerList (boolean): request a list of players
/// - player (string): the player to control
/// - requestNowPlaying (boolean): request current track info
/// - requestVolume (boolean): request current volume
/// - action (string): action to perform (Play, Pause, PlayPause, Next, Previous, Stop)
/// - setVolume (int): set player volume (0-100)
/// - Seek (int): seek position in ms
/// - SetPosition (int): set position in ms
/// - albumArtUrl (string): request album art for a URL
///
public class MPRISService: Service, DownloadTaskDelegate {
    
    let un = UNUserNotificationCenter.current()
    
    // MARK: Types
    
    public typealias PlayerIdentity = String
    
    enum UserInfoProperty: String {
        case deviceId = "com.soduto.services.mpris.deviceId"
        case playerIdentity = "com.soduto.services.mpris.playerIdentity"
    }
    
    enum ActionId: ServiceAction.Id {
        case refresh
    }
    
    private struct DownloadInfo {
        let task: DownloadTask
        let fileHash: String?
        let playerIdentity: String
        let albumArtUrl: String
        let partFileURL: URL
        let device: Device
        
        init(task: DownloadTask, fileHash: String?, playerIdentity: String, albumArtUrl: String, partFileURL: URL, device: Device) {
            self.task = task
            self.fileHash = fileHash
            self.playerIdentity = playerIdentity
            self.albumArtUrl = albumArtUrl
            self.partFileURL = partFileURL
            self.device = device
        }
    }
    
    // MARK: Service properties
    
    public static let serviceId: Service.Id = "com.soduto.services.mpris"
    
    public let incomingCapabilities = Set<Service.Capability>([ DataPacket.mprisPacketType, DataPacket.mprisRequestPacketType ])
    public let outgoingCapabilities = Set<Service.Capability>([ DataPacket.mprisRequestPacketType, DataPacket.mprisPacketType ])
    
    private var albumArtDownloadInfos: [DownloadInfo] = []
    private var downloadedAlbumArtFileURLByPlayerIdentity: [String: URL] = [:]
    private var cachedDownloadedAlbumArtFileURLByHash: [String: URL] = [:]
    
    /// Available remote players grouped by device
    @Published private var players: [String: [RemotePlayer]] = [:]
    /// Keeps track of the last player that was playing
    private var lastActivePlayer: RemotePlayer? = nil
    private var commandCenter = MPRemoteCommandCenter.shared()
    
    /// Local media controller - handles local media players that can be controlled by remote devices
    private var localMediaController = LocalMediaController()
    
    // MARK: Initialization
    
    public init() {
        setupCommandCenter()
    }
    
    // MARK: Service methods
    
    public func handleDataPacket(_ dataPacket: DataPacket, fromDevice device: Device, onConnection connection: Connection) -> Bool {
        
        guard dataPacket.isMprisPacket || dataPacket.isMprisRequestPacket else { return false }
                
        if dataPacket.isMprisPacket {
            // Handle incoming player updates from remote devices
            return handleMprisUpdate(dataPacket, fromDevice: device, onConnection: connection)
        } else if dataPacket.isMprisRequestPacket {
            // Handle incoming requests for local player control/info
            return handleMprisRequest(dataPacket, fromDevice: device, onConnection: connection)
        }
        
        return false
    }
    
    public func setup(for device: Device) {
        // Request remote player list
        requestPlayerList(from: device)
        
        // Send our local player list after a small delay to ensure the device is ready - using LocalMediaController
        let localPlayers = localMediaController.getAllLocalPlayers()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.localMediaController.sendPlayerList(to: device)
        }

        // Track connected devices - using LocalMediaController
        localMediaController.addConnectedDevice(device)
    }
    
    public func cleanup(for device: Device) {
        // Remove from connected devices - using LocalMediaController
        localMediaController.removeConnectedDevice(device)
        
        // Remove players for this device
        if let devicePlayers = players.removeValue(forKey: device.id) {
            for player in devicePlayers {
                player.cleanup()
            }
        }
        
        // Cancel any ongoing album art downloads and uploads for this device
        let downloadsToCancel = albumArtDownloadInfos.filter { $0.device.id == device.id }
        for downloadInfo in downloadsToCancel {
            downloadInfo.task.cancel()
        }
        
        // Remove download info for this device
        albumArtDownloadInfos.removeAll { $0.device.id == device.id }
        
        // Clean up any player-specific album art files (keep cache for reuse)
        let playerIdentities = Set(players.values.flatMap { $0 }.map { $0.identity })
        downloadedAlbumArtFileURLByPlayerIdentity = downloadedAlbumArtFileURLByPlayerIdentity.filter { key, _ in
            playerIdentities.contains(key)
        }
    }
    
    public func actions(for device: Device) -> [ServiceAction] {
        guard device.incomingCapabilities.contains(DataPacket.mprisRequestPacketType) || 
              device.outgoingCapabilities.contains(DataPacket.mprisPacketType) else { 
            return [] 
        }
        guard device.pairingStatus == .Paired else { 
            return [] 
        }
        
        return [
            ServiceAction(id: ActionId.refresh.rawValue, group: "setup", title: "Request Media Players", description: "Request available media players from the remote device", service: self, device: device)
        ]
    }
    
    public func performAction(_ id: ServiceAction.Id, forDevice device: Device) {
        guard let actionId = ActionId(rawValue: id) else { return }
        guard device.pairingStatus == .Paired else { return }
        
        switch actionId {
        case .refresh:
            requestPlayerList(from: device)
        }
    }
    
    // MARK: - Packet Handling Methods
    
    private func handleMprisUpdate(_ dataPacket: DataPacket, fromDevice device: Device, onConnection connection: Connection) -> Bool {
        do {
            if let playerList = try dataPacket.getPlayerList() {
                handlePlayerList(playerList, from: device)
            } else if let player = try dataPacket.getPlayer() {
                // Check if this is an album art transfer packet
                if let isTransferringAlbumArt = try dataPacket.getTransferringAlbumArt(), isTransferringAlbumArt,
                   let albumArtUrl = try dataPacket.getAlbumArtUrl(),
                   dataPacket.hasPayload(),
                   let downloadTask = dataPacket.downloadTask {
                    handleAlbumArtTransfer(player: player, albumArtUrl: albumArtUrl, downloadTask: downloadTask, from: device)
                } else {
                    // Regular player update
                    handlePlayerUpdate(player: player, packet: dataPacket, from: device)
                }
            }
        } catch {
            Log.error?.message("MPRIS::Error handling MPRIS update packet: \(error)")
        }
        
        return true
    }
    
    private func handleMprisRequest(_ dataPacket: DataPacket, fromDevice device: Device, onConnection connection: Connection) -> Bool {
        do {
            // Check if this is a request for player list
            if try dataPacket.hasRequestPlayerList() {
                localMediaController.sendPlayerList(to: device)
                return true
            }
            
            // Check if this is a player-specific request
            guard let player = try dataPacket.getPlayer() else {
                Log.warning?.message("MPRIS::Request packet without player or playerList request")
                return true
            }
            
            // Using LocalMediaController to get local player
            guard let localPlayer = localMediaController.getLocalPlayer(identity: player) else {
                Log.warning?.message("MPRIS::Request for unknown local player: \(player)")
                // Using LocalMediaController method for sending player list
                localMediaController.sendPlayerList(to: device)
                return true
            }
            
            // Handle album art request
            if let albumArtUrl = try dataPacket.getAlbumArtUrl() {
                handleAlbumArtRequest(player: player, albumArtUrl: albumArtUrl, localPlayer: localPlayer, from: device, onConnection: connection)
                return true
            }
            
            // Handle player commands
            if let action = try dataPacket.getAction() {
                // Using LocalMediaController method for handling player commands
                localMediaController.handlePlayerCommand(action: action, player: localPlayer, fromDevice: device)
            }
            
            // Handle property setters
            if let volume = try dataPacket.getSetVolume() {
                localPlayer.setVolume(volume)
                localMediaController.sendPlayerUpdate(localPlayer, to: device)
            }
            
            if let loopStatus = try dataPacket.getSetLoopStatus() {
                localPlayer.setLoopStatus(loopStatus)
                localMediaController.sendPlayerUpdate(localPlayer, to: device)
            }
            
            if let shuffle = try dataPacket.getSetShuffle() {
                localPlayer.setShuffle(shuffle)
                localMediaController.sendPlayerUpdate(localPlayer, to: device)
            }
            
            if let seekOffset = try dataPacket.getSeek() {
                localPlayer.seek(seekOffset)
                localMediaController.sendPlayerUpdate(localPlayer, to: device)
            }
            
            if let position = try dataPacket.getSetPosition() {
                Log.info?.message("MPRIS: Received SetPosition request: \(position)ms for player \(localPlayer.identity)")
                localPlayer.setPosition(position)
                localMediaController.sendPlayerUpdate(localPlayer, to: device)
            }
            
            // Handle information requests
            let hasRequestNowPlaying = (try? dataPacket.hasRequestNowPlaying()) ?? false
            let hasRequestVolume = (try? dataPacket.hasRequestVolume()) ?? false
            if hasRequestNowPlaying || hasRequestVolume {
                localMediaController.sendPlayerUpdate(localPlayer, to: device)
            }
            
        } catch {
            Log.error?.message("MPRIS::Error handling MPRIS request: \(error)")
        }
        
        return true
    }
    
    // MARK: Private methods - Album Art Upload
    
    private func handleAlbumArtRequest(player: String, albumArtUrl: String, localPlayer: LocalPlayer, from device: Device, onConnection connection: Connection) {
        // Ensure the requested albumArtUrl matches the current player's albumArtUrl
        guard !localPlayer.albumArtUrl.isEmpty && localPlayer.albumArtUrl == albumArtUrl else {
            Log.warning?.message("MPRIS::Album art request for invalid or outdated URL: \(albumArtUrl)")
            return
        }
        
        // Get artwork data from the local player
        guard let artworkData = localPlayer.albumArtData, !artworkData.isEmpty else {
            Log.warning?.message("MPRIS::No artwork data available for player: \(player)")
            return
        }
        
        Log.info?.message("MPRIS::Sending album art for player '\(player)' (\(artworkData.count) bytes)")
        
        // Create a temporary file for the album art
        let tempDir = FileManager.default.temporaryDirectory
        let tempFileName = "album-art-\(UUID().uuidString).jpg"
        let tempFileURL = tempDir.appendingPathComponent(tempFileName)
        
        do {
            // Write artwork data to temporary file
            try artworkData.write(to: tempFileURL)
            
            // Create MPRIS packet with transferringAlbumArt flag - this is key to avoid file sharing notifications
            var transferPacket = DataPacket(type: DataPacket.mprisPacketType, body: [
                "transferringAlbumArt": true as AnyObject,
                "player": player as AnyObject,
                "albumArtUrl": albumArtUrl as AnyObject
            ])
            
            // Create file input stream
            guard let fileInputStream = InputStream(url: tempFileURL) else {
                Log.error?.message("MPRIS::Failed to create input stream for album art")
                try? FileManager.default.removeItem(at: tempFileURL)
                return
            }
            
            transferPacket.payload = fileInputStream
            transferPacket.payloadSize = Int64(artworkData.count)
            
            // Create upload task
            if let uploadTask = UploadTask(packet: transferPacket, connection: connection, readQueue: DispatchQueue.global(qos: .utility)) {
                // Set payload info
                transferPacket.payloadInfo = uploadTask.payloadInfo
                
                // Send the packet - the transferringAlbumArt flag should prevent file sharing notifications
                device.send(transferPacket) { [weak self] (success, _) in
                    if success {
                        Log.debug?.message("MPRIS::Successfully sent album art for player: \(player)")
                    } else {
                        Log.error?.message("MPRIS::Failed to send album art for player: \(player)")
                    }
                    
                    // Clean up temp file
                    try? FileManager.default.removeItem(at: tempFileURL)
                }
            } else {
                Log.error?.message("MPRIS::Failed to create upload task for album art")
                try? FileManager.default.removeItem(at: tempFileURL)
            }
            
        } catch {
            Log.error?.message("MPRIS::Failed to prepare album art file: \(error)")
            try? FileManager.default.removeItem(at: tempFileURL)
        }
    }
    
    // MARK: DownloadTaskDelegate
    
    public func downloadTask(_ task: DownloadTask, finishedWithSuccess success: Bool) {
        guard let index = self.albumArtDownloadInfos.firstIndex(where: { $0.task === task }) else { 
            Log.error?.message("MPRIS::Download task not found in tracking list")
            return 
        }
        let info = self.albumArtDownloadInfos.remove(at: index)
        
        if success {
            do {
                // Create a more descriptive filename with proper extension detection
                let fileExtension: String
                if let artURL = URL(string: info.albumArtUrl),
                   !artURL.pathExtension.isEmpty {
                    fileExtension = artURL.pathExtension.lowercased()
                } else {
                    // Default to png if we can't determine the extension
                    fileExtension = "png"
                }
                
                let fileName = "\(info.playerIdentity)-albumart-\(Int(Date().timeIntervalSince1970)).\(fileExtension)"
                
                let finalFileURL = try self.renamePartFile(url: info.partFileURL, to: fileName)
                
                self.downloadedAlbumArtFileURLByPlayerIdentity[info.playerIdentity] = finalFileURL
                
                // Cache the album art using the hash
                if let fileHash = info.fileHash {
                    do {
                        let cachedFileURL = try self.copyFileToCache(url: finalFileURL, hash: fileHash)
                        self.cachedDownloadedAlbumArtFileURLByHash[fileHash] = cachedFileURL
                    } catch {
                        Log.error?.message("MPRIS::Failed to cache album art: \(error)")
                        // Continue even if caching fails
                    }
                }
                
                // Update the player with the downloaded album art
                if let devicePlayers = players[info.device.id] {
                    for player in devicePlayers {
                        if player.identity == info.playerIdentity {
                            player.updateAlbumArt(finalFileURL)
                            break
                        }
                    }
                }
                
            } catch {
                Log.error?.message("MPRIS::Error processing downloaded album art: \(error)")
            }
        } else {
            Log.error?.message("MPRIS::Album art download failed for player \(info.playerIdentity)")
            
            // Clean up the partial file
            do {
                if FileManager.default.fileExists(atPath: info.partFileURL.path) {
                    try FileManager.default.removeItem(at: info.partFileURL)
                }
            } catch {
                Log.error?.message("MPRIS::Failed to clean up partial file: \(error)")
            }
        }
    }
    

    
    // MARK: Private methods - Packet Handlers
    
    private func handlePlayerList(_ playerList: [String], from device: Device) {
        // Remove any players that are no longer available
        if var devicePlayers = players[device.id] {
            devicePlayers = devicePlayers.filter { player in
                if !playerList.contains(player.identity) {
                    player.cleanup()
                    return false
                }
                return true
            }
            players[device.id] = devicePlayers
        }
        
        // Create or update players
        var updatedPlayers = [RemotePlayer]()
        for playerIdentity in playerList {
            var existingPlayer: RemotePlayer? = nil
            
            if let devicePlayers = players[device.id] {
                existingPlayer = devicePlayers.first { $0.identity == playerIdentity }
            }
            
            if let player = existingPlayer {
                updatedPlayers.append(player)
            } else {
                let player = RemotePlayer(device: device, identity: playerIdentity)
                updatedPlayers.append(player)
            }
            
            // Request current track info and volume for all players
            requestPlayerInfo(player: playerIdentity, from: device)
        }
        
        players[device.id] = updatedPlayers
    }
    
    private func handleAlbumArtTransfer(player: String, albumArtUrl: String, downloadTask: DownloadTask, from device: Device) {
        startAlbumArtDownload(player: player, albumArtUrl: albumArtUrl, downloadTask: downloadTask, from: device)
    }
    
    private func handlePlayerUpdate(player: String, packet: DataPacket, from device: Device) {
        guard let devicePlayers = players[device.id] else { return }
        guard let playerToUpdate = devicePlayers.first(where: { $0.identity == player }) else { return }
        
        do {
            let isPlaying = try packet.getIsPlaying() ?? playerToUpdate.isPlaying
            let position = try packet.getPosition() ?? playerToUpdate.position
            let artist = try packet.getArtist() ?? playerToUpdate.artist
            let title = try packet.getTitle() ?? playerToUpdate.title
            let album = try packet.getAlbum() ?? playerToUpdate.album
            let length = try packet.getLength() ?? playerToUpdate.length
            let albumArtUrl = try packet.getAlbumArtUrl()
            let volume = try packet.getVolume() ?? playerToUpdate.volume
            let canPause = try packet.getCanPause() ?? playerToUpdate.canPause
            let canPlay = try packet.getCanPlay() ?? playerToUpdate.canPlay
            let canGoNext = try packet.getCanGoNext() ?? playerToUpdate.canGoNext
            let canGoPrevious = try packet.getCanGoPrevious() ?? playerToUpdate.canGoPrevious
            
            playerToUpdate.update(
                isPlaying: isPlaying,
                position: position,
                artist: artist,
                title: title,
                album: album,
                length: length,
                volume: volume,
                canPause: canPause,
                canPlay: canPlay,
                canGoNext: canGoNext, 
                canGoPrevious: canGoPrevious
            )
            
            // If this player is playing, set it as the last active player
            if isPlaying {
                self.lastActivePlayer = playerToUpdate
            }
            
            // Handle album art updates
            if let albumArtUrl = albumArtUrl {
                // Only request new album art if the URL has actually changed
                if playerToUpdate.albumArtUrl != albumArtUrl {
                    playerToUpdate.albumArtUrl = albumArtUrl
                    
                    // Check if we already have this album art in cache before requesting
                    if let hash = getHashForAlbumArt(player: player, albumArtUrl: albumArtUrl),
                       let cachedFileURL = getCachedAlbumArt(hash: hash) {
                        do {
                            let copiedFileURL = try copyFileFromCache(url: cachedFileURL, playerIdentity: player)
                            downloadedAlbumArtFileURLByPlayerIdentity[player] = copiedFileURL
                            playerToUpdate.updateAlbumArt(copiedFileURL)
                        } catch {
                            Log.error?.message("MPRIS::Failed to use cached album art: \(error)")
                            requestAlbumArt(player: player, albumArtUrl: albumArtUrl, from: device)
                        }
                    } else {
                        requestAlbumArt(player: player, albumArtUrl: albumArtUrl, from: device)
                    }
                }
            } else if playerToUpdate.albumArtUrl != nil {
                // Album art URL was cleared
                playerToUpdate.albumArtUrl = nil
                playerToUpdate.albumArtImage = nil
                playerToUpdate.updateNowPlayingInfo()
            }
            
            // Update the command center controls based on player capabilities
            updateCommandCenterForActivePlayer(playerToUpdate)
            
            // If this player is playing, ensure other players are marked as not playing
            if isPlaying {
                for deviceID in players.keys {
                    if let devicePlayers = players[deviceID] {
                        for otherPlayer in devicePlayers {
                            if otherPlayer !== playerToUpdate && otherPlayer.isPlaying {
                                otherPlayer.isPlaying = false
                            }
                        }
                    }
                }
            }
            
        } catch {
            Log.error?.message("MPRIS::Error parsing player update: \(error)")
        }
    }
    
    // MARK: Private methods - Remote Command Center
    
    private func setupCommandCenter() {
        // Remove all targets from command center
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.stopCommand.removeTarget(nil)
        commandCenter.togglePlayPauseCommand.removeTarget(nil)
        commandCenter.nextTrackCommand.removeTarget(nil)
        commandCenter.previousTrackCommand.removeTarget(nil)
        commandCenter.changePlaybackPositionCommand.removeTarget(nil)
        
        // Setup command handlers
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            guard let activePlayer = self?.findActivePlayer() else { return .commandFailed }
            self?.sendPauseCommand(to: activePlayer)
            return .success
        }
        
        commandCenter.playCommand.addTarget { [weak self] _ in
            guard let activePlayer = self?.findActivePlayer() else { return .commandFailed }
            self?.sendPlayCommand(to: activePlayer)
            return .success
        }
        
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let activePlayer = self?.findActivePlayer() else { return .commandFailed }
            self?.sendPlayPauseCommand(to: activePlayer)
            return .success
        }
        
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            guard let activePlayer = self?.findActivePlayer() else { return .commandFailed }
            guard activePlayer.canGoNext else { return .commandFailed }
            self?.sendNextCommand(to: activePlayer)
            return .success
        }
        
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            guard let activePlayer = self?.findActivePlayer() else { return .commandFailed }
            guard activePlayer.canGoPrevious else { return .commandFailed }
            self?.sendPreviousCommand(to: activePlayer)
            return .success
        }
        
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let activePlayer = self?.findActivePlayer() else { 
                return .commandFailed 
            }
            if let event = event as? MPChangePlaybackPositionCommandEvent {
                let position = Int(event.positionTime)
                self?.sendSetPositionCommand(to: activePlayer, position: position)
                return .success
            }
            return .commandFailed
        }
    }
    
    private func findActivePlayer() -> RemotePlayer? {
        // First, check if we have a last active player and it's still valid (exists in players dictionary)
        if let lastPlayer = lastActivePlayer {
            // Make sure this player still exists in the dictionary
            if let devicePlayers = players[lastPlayer.device.id], devicePlayers.contains(where: { $0 === lastPlayer }) {
                return lastPlayer
            } else {
                self.lastActivePlayer = nil
            }
        }
        
        // Next, look for a player that is currently playing
        for deviceID in players.keys {
            if let devicePlayers = players[deviceID] {
                for player in devicePlayers {
                    if player.isPlaying {
                        self.lastActivePlayer = player  // Update lastActivePlayer
                        return player
                    }
                }
            }
        }
        
        // If no player is playing, return the first player
        for deviceID in players.keys {
            if let devicePlayers = players[deviceID], let player = devicePlayers.first {
                return player
            }
        }
        
        return nil
    }
    
    private func updateCommandCenterForActivePlayer(_ player: RemotePlayer) {
        // Update commands availability
        commandCenter.pauseCommand.isEnabled = player.canPause
        commandCenter.playCommand.isEnabled = player.canPlay
        commandCenter.togglePlayPauseCommand.isEnabled = player.canPause || player.canPlay
        commandCenter.nextTrackCommand.isEnabled = player.canGoNext
        commandCenter.previousTrackCommand.isEnabled = player.canGoPrevious
        commandCenter.changePlaybackPositionCommand.isEnabled = player.length > 0
    }
    
    // MARK: Private methods - Player Commands
    
    private func sendPlayPauseCommand(to player: RemotePlayer) {
        player.device.send(DataPacket.mprisRequestPacket(player: player.identity, action: "PlayPause"))
    }
    
    private func sendPlayCommand(to player: RemotePlayer) {
        player.device.send(DataPacket.mprisRequestPacket(player: player.identity, action: "Play"))
    }
    
    private func sendPauseCommand(to player: RemotePlayer) {
        player.device.send(DataPacket.mprisRequestPacket(player: player.identity, action: "Pause"))
    }
    
    private func sendNextCommand(to player: RemotePlayer) {
        player.device.send(DataPacket.mprisRequestPacket(player: player.identity, action: "Next"))
    }
    
    private func sendPreviousCommand(to player: RemotePlayer) {
        player.device.send(DataPacket.mprisRequestPacket(player: player.identity, action: "Previous"))
    }
    
    private func sendStopCommand(to player: RemotePlayer) {
        player.device.send(DataPacket.mprisRequestPacket(player: player.identity, action: "Stop"))
    }
    
    private func sendSetVolumeCommand(to player: RemotePlayer, volume: Int) {
        player.device.send(DataPacket.mprisSetVolumePacket(player: player.identity, volume: volume))
    }
    
    private func sendSeekCommand(to player: RemotePlayer, offset: Int) {
        player.device.send(DataPacket.mprisSeekPacket(player: player.identity, offset: offset))
    }
    
    private func sendSetPositionCommand(to player: RemotePlayer, position: Int) {
        let positionInMs = position * 1000
        player.device.send(DataPacket.mprisSetPositionPacket(player: player.identity, position: positionInMs))
    }
    
    // MARK: Private methods - Information Requests
    
    private func requestPlayerList(from device: Device) {
        device.send(DataPacket.mprisRequestPlayerListPacket())
    }
    
    private func requestPlayerInfo(player: String, from device: Device) {
        device.send(DataPacket.mprisRequestInfoPacket(player: player))
    }
    
    private func requestAlbumArt(player: String, albumArtUrl: String, from device: Device) {
        device.send(DataPacket.mprisRequestAlbumArtPacket(player: player, albumArtUrl: albumArtUrl))
    }
        
    // MARK: Private methods - Album Art Download
    
    private func startAlbumArtDownload(player: String, albumArtUrl: String, downloadTask: DownloadTask, from device: Device) {
        let downloadFileHash = getHashForAlbumArt(player: player, albumArtUrl: albumArtUrl)
        
        // Check if we already have this album art cached
        if let hash = downloadFileHash, let cachedFileURL = getCachedAlbumArt(hash: hash) {
            do {
                let copiedFromCacheFileURL = try self.copyFileFromCache(url: cachedFileURL, playerIdentity: player)
                self.downloadedAlbumArtFileURLByPlayerIdentity[player] = copiedFromCacheFileURL
                
                // Update the player with the album art
                if let devicePlayers = players[device.id] {
                    for playerObj in devicePlayers {
                        if playerObj.identity == player {
                            playerObj.updateAlbumArt(copiedFromCacheFileURL)
                            break
                        }
                    }
                }
                return
            } catch {
                Log.error?.message("MPRIS::Failed to copy from cache: \(error)")
                // Continue with download if cache copy fails
            }
        }
        
        // Check if we already have a download in progress for this album art
        if albumArtDownloadInfos.contains(where: { $0.albumArtUrl == albumArtUrl && $0.playerIdentity == player }) {
            return
        }
        
        // Start new download
        if let (readyStream, partFileURL) = self.streamForTempDownload() {
            let downloadInfo = DownloadInfo(
                task: downloadTask,
                fileHash: downloadFileHash,
                playerIdentity: player,
                albumArtUrl: albumArtUrl,
                partFileURL: partFileURL,
                device: device
            )
            self.albumArtDownloadInfos.append(downloadInfo)
            downloadTask.delegate = self
            downloadTask.start(withStream: readyStream)
        } else {
            Log.error?.message("MPRIS::Failed to create download stream for album art")
        }
    }
    
    private func getHashForAlbumArt(player: String, albumArtUrl: String) -> String? {
        // Handle KDE Connect URLs by extracting the kdeArtHash parameter
        if albumArtUrl.hasPrefix("kdeconnect:/") {
            return extractHashFromKdeConnectUrl(albumArtUrl)
        }
        
        // Use MD5 hash like GSConnect for better cache compatibility
        let inputString = albumArtUrl // GSConnect uses just the URL for hashing
        guard let inputData = inputString.data(using: .utf8) else { return nil }
        
        var hash = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        inputData.withUnsafeBytes { bytes in
            CC_MD5(bytes.bindMemory(to: UInt8.self).baseAddress, CC_LONG(inputData.count), &hash)
        }
        
        return hash.map { String(format: "%02x", $0) }.joined()
    }
    
    private func extractHashFromKdeConnectUrl(_ url: String) -> String? {
        // Extract kdeArtHash parameter from URLs like:
        // "kdeconnect:/artUri?orig=...&kdeArtHash=1743422039"
        guard let urlComponents = URLComponents(string: url),
              let queryItems = urlComponents.queryItems else { return nil }
        
        return queryItems.first { $0.name == "kdeArtHash" }?.value
    }
    
    private func getCacheDirectory() -> URL {
        // Use a proper cache directory like GSConnect
        let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return cacheDirectory.appendingPathComponent("com.soduto.mpris", isDirectory: true)
    }
    
    private func streamForTempDownload() -> (OutputStream, URL)? {
        let temporaryDirectory = NSTemporaryDirectory()
        let randomUuidForFileName = "\(UUID().uuidString)"
        
        // Try open stream for new file. Try alternative names on fail
        var partFileURL = URL(fileURLWithPath: temporaryDirectory).appendingPathComponent("\(randomUuidForFileName).part")
        var stream: OutputStream? = nil
        
        for _ in 1...10000 {
            // Create the stream
            stream = OutputStream(toFileAtPath: partFileURL.path, append: false)
            
            if let stream = stream {
                // Try to open the stream
                stream.open()
                
                // Check if the stream opened successfully
                if stream.streamStatus == .open || stream.streamStatus == .writing {
                    return (stream, partFileURL)
                } else {
                    stream.close()
                }
            }
            
            // Try with a different filename
            let randomSuffix = arc4random()
            partFileURL = URL(fileURLWithPath: temporaryDirectory).appendingPathComponent("\(randomUuidForFileName).\(randomSuffix).part")
        }
        
        Log.error?.message("MPRIS::Failed to create download stream after 10000 attempts")
        return nil
    }

    private func renamePartFile(url partFileURL: URL, to fileName: String) throws -> URL {
        // Try rename file from temporary *.part name to final path based on original file name
        var finalFileURL = partFileURL.deletingLastPathComponent().appendingPathComponent(fileName)
        
        for _ in 1...10000 {
            if !FileManager.default.fileExists(atPath: finalFileURL.path) {
                try FileManager.default.moveItem(at: partFileURL, to: finalFileURL)
                return finalFileURL
            }
            
            let random = arc4random()
            finalFileURL = partFileURL.deletingLastPathComponent().appendingPathComponent("\(fileName).\(random)")
        }
        
        throw DataPacket.MprisError.partFileRenameFailed
    }

    private func copyFileToCache(url fileURL: URL, hash fileHash: String) throws -> URL {
        let cacheDirURL = getCacheDirectory()
        
        try FileManager.default.createDirectory(at: cacheDirURL, withIntermediateDirectories: true, attributes: nil)
        
        let cacheFileURL = cacheDirURL.appendingPathComponent(fileHash)
        
        if !FileManager.default.fileExists(atPath: cacheFileURL.path) {
            try FileManager.default.copyItem(at: fileURL, to: cacheFileURL)
        }
        
        return cacheFileURL
    }

    private func copyFileFromCache(url fileURL: URL, playerIdentity: String) throws -> URL {
        let temporaryDirectory = NSTemporaryDirectory()
        let fileName = "\(playerIdentity)-\(UUID().uuidString).png"
        let finalURL = URL(fileURLWithPath: fileName, relativeTo: URL(fileURLWithPath: temporaryDirectory, isDirectory: true))
        try FileManager.default.copyItem(at: fileURL, to: finalURL)
        return finalURL
    }
    
    private func getCachedAlbumArt(hash: String) -> URL? {
        let cacheFileURL = getCacheDirectory().appendingPathComponent(hash)
        if FileManager.default.fileExists(atPath: cacheFileURL.path) {
            return cacheFileURL
        }
        return nil
    }
}

// MARK: - Player Remote Class

class RemotePlayer: NSObject {
    // Player identity
    let device: Device
    let identity: String
    
    // Player state
    var isPlaying: Bool = false {
        didSet {
            if isPlaying != oldValue {
                updateNowPlayingInfo()
            }
        }
    }
    var position: Int = 0
    var timestamp: Date = Date()
    
    // Track metadata
    var artist: String?
    var title: String?
    var album: String?
    var albumArtUrl: String?
    var albumArtImage: NSImage?
    var length: Int = 0
    
    // Player capabilities
    var volume: Int = 50
    var canPause: Bool = false
    var canPlay: Bool = false
    var canGoNext: Bool = false
    var canGoPrevious: Bool = false
    
    // Now playing info
    private let nowPlayingInfoCenter = MPNowPlayingInfoCenter.default()
    
    init(device: Device, identity: String) {
        self.device = device
        self.identity = identity
        super.init()
    }
    
    func update(isPlaying: Bool,
                position: Int,
                artist: String?,
                title: String?,
                album: String?,
                length: Int,
                volume: Int,
                canPause: Bool,
                canPlay: Bool,
                canGoNext: Bool,
                canGoPrevious: Bool) {
        
        var needsInfoUpdate = false
        
        if self.isPlaying != isPlaying {
            self.isPlaying = isPlaying
            needsInfoUpdate = true
        }
        
        // Check if position changed significantly (more than 2 seconds difference)
        // This helps detect seeks while avoiding constant updates during normal playback
        let positionDiff = abs(self.position - position)
        if positionDiff > 2000 {
            needsInfoUpdate = true
        }
        
        self.position = position
        self.timestamp = Date()
        
        if self.artist != artist || self.title != title || self.album != album || self.length != length {
            self.artist = artist
            self.title = title
            self.album = album
            self.length = length
            needsInfoUpdate = true
        }
        
        self.volume = volume
        self.canPause = canPause
        self.canPlay = canPlay
        self.canGoNext = canGoNext
        self.canGoPrevious = canGoPrevious
        
        if needsInfoUpdate {
            updateNowPlayingInfo()
        }
    }
    
    func updateAlbumArt(_ fileURL: URL) {
        if let image = NSImage(contentsOf: fileURL) {
            self.albumArtImage = image
        } else {
            Log.error?.message("MPRIS::RemotePlayer failed to load album art image from \(fileURL.path)")
            self.albumArtImage = nil
        }
        
        updateNowPlayingInfo()
    }
    
    func updateNowPlayingInfo() {
        // Only create a new info dictionary if we don't have one or if we're playing/have content
        // This allows us to keep the now playing info visible when paused
        var nowPlayingInfo = nowPlayingInfoCenter.nowPlayingInfo ?? [String: Any]()
        
        // Set track info
        if let title = self.title, !title.isEmpty {
            nowPlayingInfo[MPMediaItemPropertyTitle] = title
        } else {
            nowPlayingInfo.removeValue(forKey: MPMediaItemPropertyTitle)
        }
        
        if let artist = self.artist, !artist.isEmpty {
            nowPlayingInfo[MPMediaItemPropertyArtist] = artist
        } else {
            nowPlayingInfo.removeValue(forKey: MPMediaItemPropertyArtist)
        }
        
        if let album = self.album, !album.isEmpty {
            nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = album
        } else {
            nowPlayingInfo.removeValue(forKey: MPMediaItemPropertyAlbumTitle)
        }
        
        // Set playback info
        if length > 0 {
            nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = TimeInterval(length / 1000)
            nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = TimeInterval(position / 1000)
        } else {
            nowPlayingInfo.removeValue(forKey: MPMediaItemPropertyPlaybackDuration)
            nowPlayingInfo.removeValue(forKey: MPNowPlayingInfoPropertyElapsedPlaybackTime)
        }
        
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        
        // Set artwork
        if let image = albumArtImage {
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in
                return image
            }
            nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
        } else {
            nowPlayingInfo.removeValue(forKey: MPMediaItemPropertyArtwork)
        }
        
        // Add device and player info for identification
        nowPlayingInfo["deviceName"] = device.name
        nowPlayingInfo["playerName"] = identity
        
        nowPlayingInfoCenter.nowPlayingInfo = nowPlayingInfo
    }
    
    func cleanup() {
        // Only clear now playing info when this player is being removed from the device
        isPlaying = false
        nowPlayingInfoCenter.nowPlayingInfo = nil
    }
}

// MARK: - Media Remote Player (Real Implementation)


// MARK: - MediaRemoteAdapter Player (Real Implementation using perl script)

class MediaRemoteBasedLocalPlayer: LocalPlayer {
    
    // MediaRemoteAdapter perl script integration
    private var streamProcess: Process?
    private var streamPipe: Pipe?
    private var streamTask: Task<Void, Never>?
    private var lastPlayerInfo: [String: Any] = [:]
    weak var parentController: LocalMediaController?
    
    override init(identity: String) {
        super.init(identity: identity)
                
        // Start monitoring media information
        startMediaMonitoring()
        
        // Initial fetch of media information
        Task {
            await fetchCurrentMediaInfo()
        }
    }
    
    deinit {
        stopMediaMonitoring()
    }
    
    // MARK: - MediaRemoteAdapter Integration
    
    private func startMediaMonitoring() {
        // Get MediaRemoteAdapter files from bundle resources
        guard let scriptPath = Bundle.main.path(forResource: "mediaremote-adapter", ofType: "pl") else {
            Log.error?.message("MediaRemoteBasedLocalPlayer: Perl script not found in bundle resources")
            return
        }
        
        // Framework is embedded, not in resources - check embedded frameworks location
        guard let frameworkPath = Bundle.main.privateFrameworksPath?.appending("/MediaRemoteAdapter.framework") ??
                Bundle.main.path(forResource: "MediaRemoteAdapter", ofType: "framework") else {
            Log.error?.message("MediaRemoteBasedLocalPlayer: Framework not found in embedded frameworks")
            return
        }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [scriptPath, frameworkPath, "stream", "--debounce=500"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe // Capture errors too
        
        streamProcess = process
        streamPipe = pipe
        
        do {
            try process.run()
            
            // Start reading from the stream
            streamTask = Task { [weak self] in
                await self?.processMediaStream()
            }
        } catch {
            Log.error?.message("MediaRemoteBasedLocalPlayer: ❌ Failed to start MediaRemoteAdapter stream: \(error)")
            streamProcess = nil
            streamPipe = nil
        }
    }
    
    private func stopMediaMonitoring() {
        streamTask?.cancel()
        streamTask = nil
        
        if let process = streamProcess, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        
        streamProcess = nil
        streamPipe = nil
    }
    
    private func processMediaStream() async {
        guard let pipe = streamPipe else { return }
        
        let fileHandle = pipe.fileHandleForReading
        var buffer = ""
        
        while !Task.isCancelled {
            do {
                let data = fileHandle.availableData
                
                if data.isEmpty {
                    // Process might have ended
                    try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                    continue
                }
                
                guard let chunk = String(data: data, encoding: .utf8) else {
                    continue
                }
                
                buffer.append(chunk)
                
                // Process complete JSON objects
                await processCompleteJSONObjects(from: &buffer)
                
            } catch {
                Log.error?.message("MediaRemoteBasedLocalPlayer: Error reading from stream: \(error)")
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                } catch {
                    // If sleep fails, just continue without delay
                    Log.debug?.message("MediaRemoteBasedLocalPlayer: Sleep interrupted: \(error)")
                }
            }
        }
    }
    
    private func processCompleteJSONObjects(from buffer: inout String) async {
        var startIndex = buffer.startIndex
        
        while startIndex < buffer.endIndex {
            // Skip whitespace and newlines
            while startIndex < buffer.endIndex && buffer[startIndex].isWhitespace {
                startIndex = buffer.index(after: startIndex)
            }
            
            // Check if we have enough data to start parsing
            guard startIndex < buffer.endIndex else { break }
            
            // Find the start of a JSON object
            if buffer[startIndex] != "{" {
                // Skip non-JSON content until we find a JSON object
                if let nextBrace = buffer[startIndex...].firstIndex(of: "{") {
                    startIndex = nextBrace
                } else {
                    // No JSON object found, clear buffer up to current position
                    buffer = String(buffer[startIndex...])
                    return
                }
                continue
            }
            
            // Find the complete JSON object by counting braces
            var braceCount = 0
            var currentIndex = startIndex
            var inString = false
            var escaped = false
            
            while currentIndex < buffer.endIndex {
                let char = buffer[currentIndex]
                
                if escaped {
                    escaped = false
                } else if char == "\\" && inString {
                    escaped = true
                } else if char == "\"" {
                    inString.toggle()
                } else if !inString {
                    if char == "{" {
                        braceCount += 1
                    } else if char == "}" {
                        braceCount -= 1
                        if braceCount == 0 {
                            // Found complete JSON object
                            let endIndex = buffer.index(after: currentIndex)
                            let jsonString = String(buffer[startIndex..<endIndex])
                            
                            // Process the complete JSON object
                            await processJSONObject(jsonString)
                            
                            // Remove processed JSON from buffer
                            buffer = String(buffer[endIndex...])
                            return
                        }
                    }
                }
                
                currentIndex = buffer.index(after: currentIndex)
            }
            
            // Incomplete JSON object, leave it in buffer for next iteration
            break
        }
    }
    
    private func processJSONObject(_ jsonString: String) async {
        guard let data = jsonString.data(using: .utf8) else { return }
        
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }
            
            // Update player information based on JSON data
            await updateFromMediaRemoteData(json)
            
        } catch {
            Log.error?.message("MediaRemoteBasedLocalPlayer: Failed to parse JSON object: \(error)")
        }
    }
    
    @MainActor
    private func updateFromMediaRemoteData(_ data: [String: Any]) {
        // Extract the payload data - MediaRemoteAdapter wraps actual data in a payload object
        guard let payload = data["payload"] as? [String: Any] else {
            return
        }
        
        var hasChanges = false
        var changesSummary: [String] = []
        
        // Update basic track info
        if let newArtist = payload["artist"] as? String {
            if newArtist != artist {
                let oldArtist = artist
                artist = newArtist
                hasChanges = true
                changesSummary.append("artist: '\(oldArtist)' → '\(artist)'")
            }
        }
        
        if let newTitle = payload["title"] as? String {
            if newTitle != title {
                let oldTitle = title
                title = newTitle
                hasChanges = true
                changesSummary.append("title: '\(oldTitle)' → '\(title)'")
            }
        }
        
        if let newAlbum = payload["album"] as? String, newAlbum != album {
            let oldAlbum = album
            album = newAlbum
            hasChanges = true
            changesSummary.append("album: '\(oldAlbum)' → '\(album)'")
        }
        
        // Update duration (keep in seconds as per property declaration)
        if let duration = payload["duration"] as? Double {
            let newLength = Int(duration) // Keep in seconds
            if newLength != length {
                let oldLength = length
                length = newLength
                hasChanges = true
                changesSummary.append("duration: \(oldLength)s → \(length)s")
            }
        }
        
        // Update position (keep in seconds as per property declaration)
        if let elapsed = payload["elapsedTime"] as? Double {
            let newPosition = Int(elapsed) // Keep in seconds
            if abs(newPosition - position) > 2 { // Only log significant position changes (>2s)
                let oldPosition = position
                position = newPosition
                hasChanges = true
                changesSummary.append("position: \(oldPosition)s → \(position)s")
            } else if newPosition != position {
                // Update position without logging for minor changes
                position = newPosition
                hasChanges = true
            }
        }
        
        // Update playback state
        if let playing = payload["playing"] as? Bool {
            if playing != isPlaying {
                isPlaying = playing
                hasChanges = true
                changesSummary.append("playing: \(!playing) → \(isPlaying)")
            }
        }
        
        // Update shuffle mode
        if let shuffleMode = payload["shuffleMode"] as? Int {
            let newShuffle = shuffleMode != 1 // Mode 1 = off, others = on
            if newShuffle != shuffle {
                shuffle = newShuffle
                hasChanges = true
                changesSummary.append("shuffle: \(!shuffle) → \(shuffle)")
            }
        }
        
        // Update repeat mode
        if let repeatModeValue = payload["repeatMode"] as? Int {
            let newLoopStatus: String
            switch repeatModeValue {
            case 1: newLoopStatus = "None"
            case 2: newLoopStatus = "Track"
            case 3: newLoopStatus = "Playlist"
            default: newLoopStatus = "None"
            }
            if newLoopStatus != loopStatus {
                let oldLoopStatus = loopStatus
                loopStatus = newLoopStatus
                hasChanges = true
                changesSummary.append("repeat: '\(oldLoopStatus)' → '\(loopStatus)'")
            }
        }
        
        // Update app information and player identity dynamically
        if let bundleId = payload["bundleIdentifier"] as? String ?? payload["parentApplicationBundleIdentifier"] as? String {
            let newAppName = getAppNameFromBundleId(bundleId)
            
            // Skip if the bundle identifier is our own app (Soduto itself)
            if !bundleId.contains("com.sidevesh.Soduto") && !newAppName.isEmpty && identity != newAppName {
                let oldIdentity = identity
                
                // Update our identity in the parent service
                updatePlayerIdentity(from: oldIdentity, to: newAppName)
                
                identity = newAppName
                hasChanges = true
                changesSummary.append("app: '\(oldIdentity)' → '\(identity)' (\(bundleId))")
            }
        }
        
        // Update artwork if available
        if let artworkDataString = payload["artworkData"] as? String, !artworkDataString.isEmpty {
            if let artworkData = Data(base64Encoded: artworkDataString.trimmingCharacters(in: .whitespacesAndNewlines)) {
                if albumArtData != artworkData {
                    albumArtData = artworkData
                    // Create a KDE Connect album art URL format that allows remote devices to request the artwork
                    // Similar to GSConnect format: "kdeconnect:/artUri?orig=...&kdeArtHash=..."
                    let artHash = createAlbumArtHash(from: artworkData)
                    let originalIdentifier = identity.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? identity
                    albumArtUrl = "kdeconnect:/artUri?orig=\(originalIdentifier)&kdeArtHash=\(artHash)"
                    hasChanges = true
                    changesSummary.append("artwork updated (\(artworkData.count) bytes)")
                }
            }
        } else if !albumArtUrl.isEmpty {
            albumArtData = nil
            albumArtUrl = ""
            hasChanges = true
            changesSummary.append("artwork cleared")
        }
        
        // Set player capabilities based on available info
        canPlay = true
        canPause = true
        canGoNext = true
        canGoPrevious = true
        canSeek = length > 0
        
        if hasChanges {
            lastUpdateTime = Date()
            lastPlayerInfo = payload // Store the payload data, not the wrapper
            
            if !changesSummary.isEmpty {
                Log.info?.message("MediaRemoteBasedLocalPlayer: ✅ Updated: \(changesSummary.joined(separator: ", "))")
            }
            
            // Trigger state change callback
            onStateChanged?()
        }
    }
    
    private func getAppNameFromBundleId(_ bundleId: String) -> String {
        // Map common bundle IDs to user-friendly names
        let knownApps: [String: String] = [
            "com.spotify.client": "Spotify",
            "com.apple.Music": "Music",
            "com.apple.Safari": "Safari",
            "com.google.Chrome": "Chrome",
            "org.mozilla.firefox": "Firefox",
            "com.microsoft.edgemac": "Edge",
            "com.apple.QuickTimePlayerX": "QuickTime Player",
            "com.apple.TV": "TV",
            "com.apple.podcasts": "Podcasts",
            "com.netflix.Netflix": "Netflix",
            "com.youtube.youtube": "YouTube",
            "com.apple.WebKit.WebContent": "Safari",
            "com.brave.Browser": "Brave",
            "com.operasoftware.Opera": "Opera",
            "com.vivaldi.Vivaldi": "Vivaldi",
            "com.soundcloud.desktop": "SoundCloud",
            "com.tidal.desktop": "TIDAL",
            "com.amazon.music": "Amazon Music",
            "com.pandora.desktop": "Pandora",
            "fm.last.desktop": "Last.fm"
        ]
        
        return knownApps[bundleId] ?? bundleId.split(separator: ".").last?.capitalized ?? "Unknown App"
    }
    
    private func updatePlayerIdentity(from oldIdentity: String, to newIdentity: String) {
        // Notify the parent service to update the player mapping
        parentController?.updateLocalPlayerIdentity(from: oldIdentity, to: newIdentity, player: self)
    }
    
    private func createAlbumArtHash(from artworkData: Data) -> String {
        // Create a simple integer hash similar to GSConnect format
        // This matches the format seen in the example: kdeArtHash=1743422039
        let hash = artworkData.hashValue
        return String(abs(hash))
    }
    
    private func fetchCurrentMediaInfo() async {
        // Get MediaRemoteAdapter files from bundle resources
        guard let scriptPath = Bundle.main.path(forResource: "mediaremote-adapter", ofType: "pl") else {
            Log.error?.message("MediaRemoteBasedLocalPlayer: Perl script not found in bundle resources")
            return
        }
        
        // Framework is embedded, not in resources - check embedded frameworks location
        guard let frameworkPath = Bundle.main.privateFrameworksPath?.appending("/MediaRemoteAdapter.framework") ??
                Bundle.main.path(forResource: "MediaRemoteAdapter", ofType: "framework") else {
            Log.error?.message("MediaRemoteBasedLocalPlayer: Framework not found in embedded frameworks")
            return
        }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [scriptPath, frameworkPath, "get"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8), !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let jsonData = output.data(using: .utf8),
                   let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                    await updateFromMediaRemoteData(json)
                }
            }
        } catch {
            Log.error?.message("MediaRemoteBasedLocalPlayer: ❌ Failed to fetch current media info: \(error)")
        }
    }
    
    // MARK: - Player Controls (using MediaRemoteAdapter commands)
    
    override func play() {
        sendMediaRemoteCommand("send", parameters: ["0"]) // kMRPlay = 0
    }
    
    override func pause() {
        sendMediaRemoteCommand("send", parameters: ["1"]) // kMRPause = 1
    }
    
    override func playPause() {
        sendMediaRemoteCommand("send", parameters: ["2"]) // kMRTogglePlayPause = 2
    }
    
    override func next() {
        sendMediaRemoteCommand("send", parameters: ["4"]) // kMRNextTrack = 4
    }
    
    override func previous() {
        sendMediaRemoteCommand("send", parameters: ["5"]) // kMRPreviousTrack = 5
    }
    
    override func stop() {
        sendMediaRemoteCommand("send", parameters: ["3"]) // kMRStop = 3
    }
    
    override func seek(_ offsetMs: Int) {
        // Convert current position from seconds to microseconds
        let currentPositionMicros = position * 1_000_000
        // Convert offset from milliseconds to microseconds
        let offsetMicros = offsetMs * 1000
        // Calculate new position and ensure it's not negative
        let newPositionMicros = max(0, currentPositionMicros + offsetMicros)
        sendMediaRemoteCommand("seek", parameters: ["\(newPositionMicros)"])
    }
    
    override func setPosition(_ positionMs: Int) {
        // Convert milliseconds to microseconds for MediaRemoteAdapter
        let positionMicros = positionMs * 1000
        Log.info?.message("MediaRemoteBasedLocalPlayer: Setting position to \(positionMs)ms (\(positionMicros) microseconds). Current position: \(position)s, length: \(length)s")
        sendMediaRemoteCommand("seek", parameters: ["\(positionMicros)"])
    }
    
    override func setVolume(_ newVolume: Int) {
        // MediaRemoteAdapter doesn't directly support volume control
        // Update local state for now
        volume = max(0, min(100, newVolume))
        lastUpdateTime = Date()
        onStateChanged?()
    }
    
    override func setShuffle(_ shuffleEnabled: Bool) {
        let shuffleMode = shuffleEnabled ? "1" : "3" // 1 = on, 3 = off
        sendMediaRemoteCommand("shuffle", parameters: [shuffleMode])
    }
    
    override func setLoopStatus(_ newLoopStatus: String) {
        let repeatMode: String
        switch newLoopStatus.lowercased() {
        case "track": repeatMode = "2"
        case "playlist": repeatMode = "3"
        default: repeatMode = "1" // None
        }
        sendMediaRemoteCommand("repeat", parameters: [repeatMode])
    }
    
    private func sendMediaRemoteCommand(_ command: String, parameters: [String] = []) {
        // Get MediaRemoteAdapter files from bundle resources
        guard let scriptPath = Bundle.main.path(forResource: "mediaremote-adapter", ofType: "pl") else {
            Log.error?.message("MediaRemoteBasedLocalPlayer: Perl script not found in bundle resources")
            return
        }
        
        // Framework is embedded, not in resources - check embedded frameworks location
        guard let frameworkPath = Bundle.main.privateFrameworksPath?.appending("/MediaRemoteAdapter.framework") ??
                Bundle.main.path(forResource: "MediaRemoteAdapter", ofType: "framework") else {
            Log.error?.message("MediaRemoteBasedLocalPlayer: Framework not found in embedded frameworks")
            return
        }
        
        Task {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            process.arguments = [scriptPath, frameworkPath, command] + parameters
            
            // Create pipes to capture output
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            
            do {
                try process.run()
                process.waitUntilExit()
                
                // Read output and error data
                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let outputString = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let errorString = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                
                let success = process.terminationStatus == 0
                if success {
                    Log.info?.message("MediaRemoteBasedLocalPlayer: ✅ Successfully sent \(command) command with parameters: \(parameters)")

                    // Trigger state change callback
                    await MainActor.run {
                        onStateChanged?()
                    }
                    
                    // Fetch updated info after successful command
                    try await Task.sleep(nanoseconds: 100_000_000) // 100 milliseconds
                    await fetchCurrentMediaInfo()
                } else {
                    var errorMessage = "MediaRemoteBasedLocalPlayer: ❌ Failed to send \(command) command (exit code: \(process.terminationStatus))"
                    if !outputString.isEmpty {
                        errorMessage += " - stdout: \(outputString)"
                    }
                    if !errorString.isEmpty {
                        errorMessage += " - stderr: \(errorString)"
                    }
                    Log.warning?.message(errorMessage)
                }
                
            } catch {
                Log.error?.message("MediaRemoteBasedLocalPlayer: ❌ Error sending \(command) command: \(error)")
            }
        }
    }
    
    // Override state method to include MediaRemoteAdapter specific info
    override func getCurrentState() -> [String: Any] {
        var state = super.getCurrentState()
        
        // Add MediaRemoteAdapter specific information
        state["mediaSource"] = "MediaRemoteAdapter"
        state["lastPlayerInfo"] = lastPlayerInfo
        
        // Add artwork data if available
        if let artworkData = albumArtData {
            state["hasArtwork"] = true
            state["artworkSize"] = artworkData.count
        }
        
        return state
    }
}

/// Local media player that can be controlled from remote devices
/// This represents a media player running on the Mac that can be controlled from remote devices
class LocalPlayer: NSObject {
    
    // Player identity and metadata
    internal(set) var identity: String
    var isPlaying: Bool = false {
        didSet {
            if isPlaying != oldValue {
                onStateChanged?()
            }
        }
    }
    var position: Int = 0 // in seconds
    var lastUpdateTime: Date = Date()
    
    // Track metadata
    var artist: String = "" {
        didSet { onStateChanged?() }
    }
    var title: String = "" {
        didSet { onStateChanged?() }
    }
    var album: String = "" {
        didSet { onStateChanged?() }
    }
    var albumArtUrl: String = ""
    var albumArtData: Data? = nil // Raw image data for artwork
    var length: Int = 0 // in seconds
    
    // Player capabilities
    var volume: Int = 50 { // 0-100
        didSet { onStateChanged?() }
    }
    var canPause: Bool = true
    var canPlay: Bool = true
    var canGoNext: Bool = true
    var canGoPrevious: Bool = true
    var canSeek: Bool = true
    var loopStatus: String = "None" { // "None", "Track", "Playlist"
        didSet { onStateChanged?() }
    }
    var shuffle: Bool = false {
        didSet { onStateChanged?() }
    }
    
    // Player state tracking
    private var positionTimer: Timer?
    
    // Callback for state changes
    var onStateChanged: (() -> Void)?
    
    init(identity: String) {
        self.identity = identity
        super.init()
        
        // Start position tracking timer
        startPositionTimer()
    }
    
    deinit {
        stopPositionTimer()
    }
    
    // MARK: - Position Tracking
    
    private func startPositionTimer() {
        positionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.isPlaying {
                self.position += 1
                if self.position >= self.length {
                    // Track ended
                    if self.loopStatus == "Track" {
                        self.position = 0
                    } else {
                        self.position = self.length
                        self.isPlaying = false
                    }
                }
                self.lastUpdateTime = Date()
            }
        }
    }
    
    private func stopPositionTimer() {
        positionTimer?.invalidate()
        positionTimer = nil
    }
    
    // MARK: - Player Controls
    
    func play() {
        Log.debug?.message("Player: Play command")
        if !isPlaying {
            isPlaying = true
            lastUpdateTime = Date()
        }
    }
    
    func pause() {
        Log.debug?.message("Player: Pause command")
        if isPlaying {
            isPlaying = false
            lastUpdateTime = Date()
        }
    }
    
    func playPause() {
        Log.debug?.message("Player: PlayPause command")
        if isPlaying {
            pause()
        } else {
            play()
        }
    }
    
    func next() {
        Log.debug?.message("Player: Next command")
        // Base implementation - subclasses should override for actual functionality
        lastUpdateTime = Date()
    }
    
    func previous() {
        Log.debug?.message("Player: Previous command")
        // Base implementation - subclasses should override for actual functionality
        lastUpdateTime = Date()
    }
    
    func stop() {
        Log.debug?.message("Player: Stop command")
        isPlaying = false
        position = 0
        lastUpdateTime = Date()
    }
    
    func setVolume(_ newVolume: Int) {
        Log.debug?.message("Player: Set volume to \(newVolume)")
        volume = max(0, min(100, newVolume))
        lastUpdateTime = Date()
    }
    
    func seek(_ offsetMs: Int) {
        Log.debug?.message("Player: Seek by \(offsetMs)ms")
        let offsetSeconds = offsetMs / 1000
        position = max(0, min(length, position + offsetSeconds))
        lastUpdateTime = Date()
    }
    
    func setPosition(_ positionMs: Int) {
        Log.debug?.message("Player: Set position to \(positionMs)ms")
        let positionSeconds = positionMs / 1000
        position = max(0, min(length, positionSeconds))
        lastUpdateTime = Date()
    }
    
    func setLoopStatus(_ status: String) {
        Log.debug?.message("Player: Set loop status to \(status)")
        loopStatus = status
        lastUpdateTime = Date()
    }
    
    func setShuffle(_ shuffleEnabled: Bool) {
        Log.debug?.message("Player: Set shuffle to \(shuffleEnabled)")
        shuffle = shuffleEnabled
        lastUpdateTime = Date()
    }
    
    // MARK: - Identity Management
    
    /// Update the player identity (used for dynamic player names)
    func updateIdentity(_ newIdentity: String) {
        identity = newIdentity
        Log.debug?.message("LocalPlayer: Identity updated to: \(newIdentity)")
    }
    
    // MARK: - State Information
    
    /// Get current player state as a dictionary for sending in MPRIS packets
    func getCurrentState() -> [String: Any] {
        return [
            "player": identity,
            "pos": position * 1000, // Convert seconds to milliseconds for remote devices
            "isPlaying": isPlaying,
            "canPause": canPause,
            "canPlay": canPlay,
            "canGoNext": canGoNext,
            "canGoPrevious": canGoPrevious,
            "canSeek": canSeek,
            "loopStatus": loopStatus,
            "shuffle": shuffle,
            "albumArtUrl": albumArtUrl,
            "length": length * 1000, // Convert seconds to milliseconds for remote devices
            "artist": artist,
            "title": title,
            "album": album,
            "nowPlaying": "\(artist) - \(title)",
            "volume": volume
        ]
    }
}

// MARK: - DataPacket (MPRIS)

/// MPRIS service data packet utilities
fileprivate extension DataPacket {
    
    // MARK: Types
    
    enum MprisError: Error {
        case wrongType
        case invalidPlayer
        case invalidPlayerList
        case invalidArtUrl
        case invalidIsPlaying
        case invalidCanPause
        case invalidCanPlay
        case invalidCanGoNext
        case invalidCanGoPrevious
        case invalidPosition
        case invalidLength
        case invalidArtist
        case invalidTitle
        case invalidAlbum
        case invalidVolume
        case invalidTransferringAlbumArt
        case partFileRenameFailed
        case invalidAction
        case invalidSetVolume
        case invalidSetLoopStatus
        case invalidSetShuffle
        case invalidSeek
        case invalidSetPosition
    }
    
    enum MprisProperty: String {
        case playerList = "playerList"
        case player = "player"
        case isPlaying = "isPlaying"
        case canPause = "canPause"
        case canPlay = "canPlay"
        case canGoNext = "canGoNext"
        case canGoPrevious = "canGoPrevious"
        case pos = "pos"
        case length = "length"
        case artist = "artist"
        case title = "title"
        case album = "album"
        case albumArtUrl = "albumArtUrl"
        case volume = "volume"
        case supportAlbumArtPayload = "supportAlbumArtPayload"
        case transferringAlbumArt = "transferringAlbumArt"
        case action = "action"
        case requestPlayerList = "requestPlayerList"
        case requestNowPlaying = "requestNowPlaying"
        case requestVolume = "requestVolume"
        case setVolume = "setVolume"
        case setLoopStatus = "setLoopStatus"
        case setShuffle = "setShuffle"
        case Seek = "Seek"
        case SetPosition = "SetPosition"
        case loopStatus = "loopStatus"
        case shuffle = "shuffle"
        case canSeek = "canSeek"
        case nowPlaying = "nowPlaying"
    }
    
    // MARK: Properties
    
    static let mprisPacketType = "kdeconnect.mpris"
    static let mprisRequestPacketType = "kdeconnect.mpris.request"
    
    var isMprisPacket: Bool { return self.type == DataPacket.mprisPacketType }
    var isMprisRequestPacket: Bool { return self.type == DataPacket.mprisRequestPacketType }
    
    
    // MARK: Public static methods
    
    static func mprisRequestPlayerListPacket() -> DataPacket {
        return DataPacket(type: mprisRequestPacketType, body: [
            MprisProperty.requestPlayerList.rawValue: true as AnyObject
        ])
    }
    
    static func mprisRequestInfoPacket(player: String) -> DataPacket {
        return DataPacket(type: mprisRequestPacketType, body: [
            MprisProperty.player.rawValue: player as AnyObject,
            MprisProperty.requestNowPlaying.rawValue: true as AnyObject,
            MprisProperty.requestVolume.rawValue: true as AnyObject
        ])
    }
    
    static func mprisRequestAlbumArtPacket(player: String, albumArtUrl: String) -> DataPacket {
        return DataPacket(type: mprisRequestPacketType, body: [
            MprisProperty.player.rawValue: player as AnyObject,
            MprisProperty.albumArtUrl.rawValue: albumArtUrl as AnyObject
        ])
    }
    
    static func mprisRequestPacket(player: String, action: String) -> DataPacket {
        return DataPacket(type: mprisRequestPacketType, body: [
            MprisProperty.player.rawValue: player as AnyObject,
            MprisProperty.action.rawValue: action as AnyObject
        ])
    }
    
    static func mprisSetVolumePacket(player: String, volume: Int) -> DataPacket {
        return DataPacket(type: mprisRequestPacketType, body: [
            MprisProperty.player.rawValue: player as AnyObject,
            MprisProperty.setVolume.rawValue: volume as AnyObject
        ])
    }
    
    static func mprisSeekPacket(player: String, offset: Int) -> DataPacket {
        return DataPacket(type: mprisRequestPacketType, body: [
            MprisProperty.player.rawValue: player as AnyObject,
            MprisProperty.Seek.rawValue: offset as AnyObject
        ])
    }
    
    static func mprisSetPositionPacket(player: String, position: Int) -> DataPacket {
        return DataPacket(type: mprisRequestPacketType, body: [
            MprisProperty.player.rawValue: player as AnyObject,
            MprisProperty.SetPosition.rawValue: position as AnyObject
        ])
    }
    
    // MARK: Public methods
    
    func validateMprisType() throws {
        guard self.isMprisPacket || self.isMprisRequestPacket else { throw MprisError.wrongType }
    }
    
    func getPlayer() throws -> String? {
        try validateMprisType()
        guard body.keys.contains(MprisProperty.player.rawValue) else { return nil }
        guard let value = body[MprisProperty.player.rawValue] as? String else { throw MprisError.invalidPlayer }
        return value
    }
    
    func getPlayerList() throws -> [String]? {
        try validateMprisType()
        guard body.keys.contains(MprisProperty.playerList.rawValue) else { return nil }
        guard let value = body[MprisProperty.playerList.rawValue] as? [String] else { throw MprisError.invalidPlayerList }
        return value
    }
    
    func getAlbumArtUrl() throws -> String? {
        try validateMprisType()
        guard body.keys.contains(MprisProperty.albumArtUrl.rawValue) else { return nil }
        guard let value = body[MprisProperty.albumArtUrl.rawValue] as? String else { throw MprisError.invalidArtUrl }
        return value
    }
    
    func getIsPlaying() throws -> Bool? {
        try validateMprisType()
        guard body.keys.contains(MprisProperty.isPlaying.rawValue) else { return nil }
        guard let value = body[MprisProperty.isPlaying.rawValue] as? Bool else { throw MprisError.invalidIsPlaying }
        return value
    }
    
    func getCanPause() throws -> Bool? {
        try validateMprisType()
        guard body.keys.contains(MprisProperty.canPause.rawValue) else { return nil }
        guard let value = body[MprisProperty.canPause.rawValue] as? Bool else { throw MprisError.invalidCanPause }
        return value
    }
    
    func getCanPlay() throws -> Bool? {
        try validateMprisType()
        guard body.keys.contains(MprisProperty.canPlay.rawValue) else { return nil }
        guard let value = body[MprisProperty.canPlay.rawValue] as? Bool else { throw MprisError.invalidCanPlay }
        return value
    }
    
    func getCanGoNext() throws -> Bool? {
        try validateMprisType()
        guard body.keys.contains(MprisProperty.canGoNext.rawValue) else { return nil }
        guard let value = body[MprisProperty.canGoNext.rawValue] as? Bool else { throw MprisError.invalidCanGoNext }
        return value
    }
    
    func getCanGoPrevious() throws -> Bool? {
        try validateMprisType()
        guard body.keys.contains(MprisProperty.canGoPrevious.rawValue) else { return nil }
        guard let value = body[MprisProperty.canGoPrevious.rawValue] as? Bool else { throw MprisError.invalidCanGoPrevious }
        return value
    }
    
    func getPosition() throws -> Int? {
        try validateMprisType()
        guard body.keys.contains(MprisProperty.pos.rawValue) else { return nil }
        guard let value = body[MprisProperty.pos.rawValue] as? Int else { throw MprisError.invalidPosition }
        return value
    }
    
    func getLength() throws -> Int? {
        try validateMprisType()
        guard body.keys.contains(MprisProperty.length.rawValue) else { return nil }
        guard let value = body[MprisProperty.length.rawValue] as? Int else { throw MprisError.invalidLength }
        return value
    }
    
    func getArtist() throws -> String? {
        try validateMprisType()
        guard body.keys.contains(MprisProperty.artist.rawValue) else { return nil }
        guard let value = body[MprisProperty.artist.rawValue] as? String else { throw MprisError.invalidArtist }
        return value
    }
    
    func getTitle() throws -> String? {
        try validateMprisType()
        guard body.keys.contains(MprisProperty.title.rawValue) else { return nil }
        guard let value = body[MprisProperty.title.rawValue] as? String else { throw MprisError.invalidTitle }
        return value
    }
    
    func getAlbum() throws -> String? {
        try validateMprisType()
        guard body.keys.contains(MprisProperty.album.rawValue) else { return nil }
        guard let value = body[MprisProperty.album.rawValue] as? String else { throw MprisError.invalidAlbum }
        return value
    }
    
    func getVolume() throws -> Int? {
        try validateMprisType()
        guard body.keys.contains(MprisProperty.volume.rawValue) else { return nil }
        guard let value = body[MprisProperty.volume.rawValue] as? Int else { throw MprisError.invalidVolume }
        return value
    }
    
    func getTransferringAlbumArt() throws -> Bool? {
        try validateMprisType()
        guard body.keys.contains(MprisProperty.transferringAlbumArt.rawValue) else { return nil }
        guard let value = body[MprisProperty.transferringAlbumArt.rawValue] as? Bool else { 
            throw MprisError.invalidTransferringAlbumArt 
        }
        return value
    }
    
    // MARK: - Request Packet Methods
    
    func hasRequestPlayerList() throws -> Bool {
        try validateMprisType()
        return body.keys.contains(MprisProperty.requestPlayerList.rawValue)
    }
    
    func hasRequestNowPlaying() throws -> Bool {
        try validateMprisType()
        return body.keys.contains(MprisProperty.requestNowPlaying.rawValue)
    }
    
    func hasRequestVolume() throws -> Bool {
        try validateMprisType()
        return body.keys.contains(MprisProperty.requestVolume.rawValue)
    }
    
    func getAction() throws -> String? {
        try validateMprisType()
        guard body.keys.contains(MprisProperty.action.rawValue) else { return nil }
        guard let value = body[MprisProperty.action.rawValue] as? String else { 
            throw MprisError.invalidAction 
        }
        return value
    }
    
    func getSetVolume() throws -> Int? {
        try validateMprisType()
        guard body.keys.contains(MprisProperty.setVolume.rawValue) else { return nil }
        guard let value = body[MprisProperty.setVolume.rawValue] as? Int else { 
            throw MprisError.invalidSetVolume 
        }
        return value
    }
    
    func getSetLoopStatus() throws -> String? {
        try validateMprisType()
        guard body.keys.contains(MprisProperty.setLoopStatus.rawValue) else { return nil }
        guard let value = body[MprisProperty.setLoopStatus.rawValue] as? String else { 
            throw MprisError.invalidSetLoopStatus 
        }
        return value
    }
    
    func getSetShuffle() throws -> Bool? {
        try validateMprisType()
        guard body.keys.contains(MprisProperty.setShuffle.rawValue) else { return nil }
        guard let value = body[MprisProperty.setShuffle.rawValue] as? Bool else { 
            throw MprisError.invalidSetShuffle 
        }
        return value
    }
    
    func getSeek() throws -> Int? {
        try validateMprisType()
        guard body.keys.contains(MprisProperty.Seek.rawValue) else { return nil }
        guard let value = body[MprisProperty.Seek.rawValue] as? Int else { 
            throw MprisError.invalidSeek 
        }
        return value
    }
    
    func getSetPosition() throws -> Int? {
        try validateMprisType()
        guard body.keys.contains(MprisProperty.SetPosition.rawValue) else { return nil }
        guard let value = body[MprisProperty.SetPosition.rawValue] as? Int else { 
            throw MprisError.invalidSetPosition 
        }
        return value
    }
    
    // MARK: - Packet Creation Methods for Local Players
    
    static func mprisPlayerListPacket(playerList: [String], supportAlbumArt: Bool) -> DataPacket {
        return DataPacket(type: mprisPacketType, body: [
            MprisProperty.playerList.rawValue: playerList as AnyObject,
            MprisProperty.supportAlbumArtPayload.rawValue: supportAlbumArt as AnyObject
        ])
    }
    
    static func mprisUpdatePacket(state: [String: Any]) -> DataPacket {
        var body: [String: AnyObject] = [:]
        
        for (key, value) in state {
            body[key] = value as AnyObject
        }
        
        return DataPacket(type: mprisPacketType, body: body)
    }

}
