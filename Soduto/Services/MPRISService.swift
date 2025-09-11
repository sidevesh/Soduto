//
//  MPRISService.swift
//  Soduto
//
//  Created by AI Assistant on 2025-05-20.
//  Copyright © 2025 Soduto. All rights reserved.
//

import Foundation
import Cocoa
import CleanroomLogger
import MediaPlayer
import UserNotifications
import CommonCrypto

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
    @Published private var players: [String: [PlayerRemote]] = [:]
    /// Keeps track of the last player that was playing
    private var lastActivePlayer: PlayerRemote? = nil
    private var nowPlayingInfoCenter = MPNowPlayingInfoCenter.default()
    private var commandCenter = MPRemoteCommandCenter.shared()
    
    /// Local media players that can be controlled by remote devices
    private var localPlayers: [String: PlayerLocal] = [:]
    /// Track connected devices for broadcasting updates
    private var connectedDevices: [String: Device] = [:]
    
    // MARK: Initialization
    
    public init() {
        setupCommandCenter()
        setupLocalPlayers()
        
        // Clean up old cache files on startup
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.cleanupOldCacheFiles()
            self?.logCacheStats()
        }
    }
    
    // MARK: Service methods
    
    public func handleDataPacket(_ dataPacket: DataPacket, fromDevice device: Device, onConnection connection: Connection) -> Bool {
        
        // Handle both MPRIS update packets and request packets
        guard dataPacket.isMprisPacket || dataPacket.isMprisRequestPacket else { return false }
        
        Log.debug?.message("MPRIS::handleDataPacket(<\(dataPacket)> fromDevice:<\(device)> onConnection:<\(connection)>)")
        
        if dataPacket.isMprisPacket {
            // Handle incoming player updates from remote devices
            return handleMprisUpdate(dataPacket, fromDevice: device)
        } else if dataPacket.isMprisRequestPacket {
            // Handle incoming requests for local player control/info
            return handleMprisRequest(dataPacket, fromDevice: device)
        }
        
        return false
    }
    
    public func setup(for device: Device) {
        Log.debug?.message("MPRIS::Setting up service for device: \(device.name)")
        
        // Track connected devices
        connectedDevices[device.id] = device
        
        // Request remote player list
        requestPlayerList(from: device)
        
        // Send our local player list after a small delay to ensure the device is ready
        Log.debug?.message("MPRIS::Scheduling player list send to \(device.name), we have \(localPlayers.count) local players")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            Log.debug?.message("MPRIS::Sending delayed player list to \(device.name)")
            self?.sendPlayerList(to: device)
        }
    }
    
    public func cleanup(for device: Device) {
        // Remove from connected devices
        connectedDevices.removeValue(forKey: device.id)
        
        // Remove players for this device
        if let devicePlayers = players.removeValue(forKey: device.id) {
            for player in devicePlayers {
                player.cleanup()
            }
        }
        
        // Cancel any ongoing album art downloads for this device
        let downloadsToCancel = albumArtDownloadInfos.filter { $0.device.id == device.id }
        for downloadInfo in downloadsToCancel {
            Log.debug?.message("MPRIS::Cancelling album art download for device \(device.name)")
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
            Log.debug?.message("MPRIS::Device \(device.name) doesn't support MPRIS capabilities")
            return [] 
        }
        guard device.pairingStatus == .Paired else { 
            Log.debug?.message("MPRIS::Device \(device.name) is not paired")
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
    
    private func handleMprisUpdate(_ dataPacket: DataPacket, fromDevice device: Device) -> Bool {
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
    
    private func handleMprisRequest(_ dataPacket: DataPacket, fromDevice device: Device) -> Bool {
        Log.debug?.message("MPRIS::Handling MPRIS request from \(device.name)")
        
        do {
            // Check if this is a request for player list
            if try dataPacket.hasRequestPlayerList() {
                Log.debug?.message("MPRIS::Received player list request from \(device.name)")
                sendPlayerList(to: device)
                return true
            }
            
            // Check if this is a player-specific request
            guard let player = try dataPacket.getPlayer() else {
                Log.warning?.message("MPRIS::Request packet without player or playerList request")
                return true
            }
            
            guard let localPlayer = localPlayers[player] else {
                Log.warning?.message("MPRIS::Request for unknown local player: \(player)")
                sendPlayerList(to: device) // Send updated player list
                return true
            }
            
            // Handle album art request
            if let albumArtUrl = try dataPacket.getAlbumArtUrl() {
                // TODO: Implement album art transfer for local players
                Log.debug?.message("MPRIS::Album art request for \(player): \(albumArtUrl)")
                return true
            }
            
            // Handle player commands
            if let action = try dataPacket.getAction() {
                handlePlayerCommand(action: action, player: localPlayer, fromDevice: device)
            }
            
            // Handle property setters
            if let volume = try dataPacket.getSetVolume() {
                localPlayer.setVolume(volume)
                sendPlayerUpdate(localPlayer, to: device)
            }
            
            if let loopStatus = try dataPacket.getSetLoopStatus() {
                localPlayer.setLoopStatus(loopStatus)
                sendPlayerUpdate(localPlayer, to: device)
            }
            
            if let shuffle = try dataPacket.getSetShuffle() {
                localPlayer.setShuffle(shuffle)
                sendPlayerUpdate(localPlayer, to: device)
            }
            
            if let seekOffset = try dataPacket.getSeek() {
                localPlayer.seek(seekOffset)
                sendPlayerUpdate(localPlayer, to: device)
            }
            
            if let position = try dataPacket.getSetPosition() {
                localPlayer.setPosition(position)
                sendPlayerUpdate(localPlayer, to: device)
            }
            
            // Handle information requests
            let hasRequestNowPlaying = (try? dataPacket.hasRequestNowPlaying()) ?? false
            let hasRequestVolume = (try? dataPacket.hasRequestVolume()) ?? false
            if hasRequestNowPlaying || hasRequestVolume {
                sendPlayerUpdate(localPlayer, to: device)
            }
            
        } catch {
            Log.error?.message("MPRIS::Error handling MPRIS request: \(error)")
        }
        
        return true
    }
    
    // MARK: - Local Player Management
    
    private func setupLocalPlayers() {
        Log.debug?.message("MPRIS::Setting up local players")
        
        // Create a real media remote player with dynamic naming
        let mediaRemotePlayer = MediaRemotePlayer(identity: "macOS.NowPlaying")
        
        // Check if MediaRemote framework loaded successfully
        if mediaRemotePlayer.isMediaRemoteAvailable {
            // Set up state change callback that also handles player identity changes
            mediaRemotePlayer.onStateChanged = { [weak self] in
                Log.debug?.message("MPRIS::MediaRemote player state changed, broadcasting update")
                self?.handleMediaRemotePlayerUpdate(mediaRemotePlayer)
            }
            
            localPlayers[mediaRemotePlayer.identity] = mediaRemotePlayer
            Log.debug?.message("MPRIS::Created MediaRemote local player: \(mediaRemotePlayer.identity)")
        } else {
            Log.error?.message("MPRIS::MediaRemote framework not available - no local players will be available")
        }
    }
    
    private func handleMediaRemotePlayerUpdate(_ player: MediaRemotePlayer) {
        // Check if the app has changed and we need to update the player identity
        let currentAppName = player.getCurrentAppName()
        let expectedIdentity: String
        
        if !currentAppName.isEmpty && currentAppName != "Unknown App" {
            expectedIdentity = currentAppName
        } else {
            expectedIdentity = "macOS.NowPlaying"
        }
        
        // If the identity should change, update our player mapping
        if player.identity != expectedIdentity {
            Log.info?.message("MPRIS::Player identity changing from '\(player.identity)' to '\(expectedIdentity)'")
            
            // Remove old identity
            localPlayers.removeValue(forKey: player.identity)
            
            // Update player identity
            player.updateIdentity(expectedIdentity)
            
            // Add with new identity
            localPlayers[expectedIdentity] = player
            
            Log.info?.message("MPRIS::Updated local players list: \(Array(localPlayers.keys))")
            
            // Send updated player list to all connected devices
            for (_, device) in connectedDevices {
                Log.debug?.message("MPRIS::Sending updated player list to \(device.name) due to identity change")
                sendPlayerList(to: device)
            }
        }
        
        // Broadcast the update
        broadcastPlayerUpdate(player)
    }
    
    private func handlePlayerCommand(action: String, player: PlayerLocal, fromDevice device: Device) {
        Log.debug?.message("MPRIS::Handling action '\(action)' for player \(player.identity) from \(device.name)")
        
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
            Log.warning?.message("MPRIS::Unknown action: \(action)")
            return
        }
        
        // Send updated player state
        sendPlayerUpdate(player, to: device)
    }
    
    private func sendPlayerList(to device: Device) {
        let playerIdentities = Array(localPlayers.keys)
        Log.debug?.message("MPRIS::Sending player list to \(device.name): \(playerIdentities)")
        
        // Create the packet body exactly like GSConnect does
        let packet = DataPacket(type: DataPacket.mprisPacketType, body: [
            "playerList": playerIdentities as AnyObject,
            "supportAlbumArtPayload": true as AnyObject
        ])
        
        Log.debug?.message("MPRIS::Player list packet body: \(packet.body)")
        device.send(packet)
        
        // Also send initial state for each player (like GSConnect does)
        for (_, player) in localPlayers {
            Log.debug?.message("MPRIS::Sending initial state for player: \(player.identity)")
            sendPlayerUpdate(player, to: device)
        }
    }
    
    private func sendPlayerUpdate(_ player: PlayerLocal, to device: Device) {
        let state = player.getCurrentState()
        Log.debug?.message("MPRIS::Sending player update for \(player.identity) to \(device.name)")
        Log.debug?.message("MPRIS::Player state: \(state)")
        
        let packet = DataPacket.mprisUpdatePacket(state: state)
        Log.debug?.message("MPRIS::Update packet body: \(packet.body)")
        device.send(packet)
    }
    
    private func broadcastPlayerUpdate(_ player: PlayerLocal) {
        // Send updates to all connected devices
        for (_, device) in connectedDevices {
            sendPlayerUpdate(player, to: device)
        }
    }
    
    // MARK: DownloadTaskDelegate
    
    public func downloadTask(_ task: DownloadTask, finishedWithSuccess success: Bool) {
        Log.debug?.message("MPRIS::downloadTask(<\(task)> finishedWithSuccess:<\(success)>)")
        
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
                Log.debug?.message("MPRIS::Album art downloaded to: \(finalFileURL.path)")
                
                self.downloadedAlbumArtFileURLByPlayerIdentity[info.playerIdentity] = finalFileURL
                
                // Cache the album art using the hash
                if let fileHash = info.fileHash {
                    do {
                        let cachedFileURL = try self.copyFileToCache(url: finalFileURL, hash: fileHash)
                        self.cachedDownloadedAlbumArtFileURLByHash[fileHash] = cachedFileURL
                        Log.debug?.message("MPRIS::Album art cached with hash \(fileHash) at \(cachedFileURL.path)")
                    } catch {
                        Log.error?.message("MPRIS::Failed to cache album art: \(error)")
                        // Continue even if caching fails
                    }
                }
                
                // Update the player with the downloaded album art
                if let devicePlayers = players[info.device.id] {
                    for player in devicePlayers {
                        if player.identity == info.playerIdentity {
                            Log.debug?.message("MPRIS::Updating player \(player.identity) with downloaded album art")
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
        Log.debug?.message("MPRIS::Handle player list \(playerList) from device \(device.name)")
        
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
        var updatedPlayers = [PlayerRemote]()
        for playerIdentity in playerList {
            var existingPlayer: PlayerRemote? = nil
            
            if let devicePlayers = players[device.id] {
                existingPlayer = devicePlayers.first { $0.identity == playerIdentity }
            }
            
            if let player = existingPlayer {
                updatedPlayers.append(player)
            } else {
                let player = PlayerRemote(device: device, identity: playerIdentity)
                updatedPlayers.append(player)
            }
            
            // Request current track info and volume for all players
            requestPlayerInfo(player: playerIdentity, from: device)
        }
        
        players[device.id] = updatedPlayers
    }
    
    private func handleAlbumArtTransfer(player: String, albumArtUrl: String, downloadTask: DownloadTask, from device: Device) {
        Log.debug?.message("MPRIS::Handle album art transfer for player \(player) from device \(device.name)")
        startAlbumArtDownload(player: player, albumArtUrl: albumArtUrl, downloadTask: downloadTask, from: device)
    }
    
    private func handlePlayerUpdate(player: String, packet: DataPacket, from device: Device) {
        Log.debug?.message("MPRIS::Handle player update for \(player) from device \(device.name)")
        
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
                Log.debug?.message("MPRIS::handlePlayerUpdate - setting lastActivePlayer to: \(player)")
                self.lastActivePlayer = playerToUpdate
            }
            
            // Handle album art updates
            if let albumArtUrl = albumArtUrl {
                // Only request new album art if the URL has actually changed
                if playerToUpdate.albumArtUrl != albumArtUrl {
                    Log.debug?.message("MPRIS::Album art URL changed for \(player): \(albumArtUrl)")
                    playerToUpdate.albumArtUrl = albumArtUrl
                    
                    // Check if we already have this album art in cache before requesting
                    if let hash = getHashForAlbumArt(player: player, albumArtUrl: albumArtUrl),
                       let cachedFileURL = getCachedAlbumArt(hash: hash) {
                        Log.debug?.message("MPRIS::Using cached album art for \(player)")
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
                Log.debug?.message("MPRIS::Album art cleared for \(player)")
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
                                Log.debug?.message("MPRIS::handlePlayerUpdate - marking \(otherPlayer.identity) as not playing")
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
            Log.debug?.message("MPRIS::changePlaybackPositionCommand triggered")
            guard let activePlayer = self?.findActivePlayer() else { 
                Log.debug?.message("MPRIS::changePlaybackPositionCommand - no active player found")
                return .commandFailed 
            }
            if let event = event as? MPChangePlaybackPositionCommandEvent {
                let position = Int(event.positionTime)
                Log.debug?.message("MPRIS::changePlaybackPositionCommand - activePlayer: \(activePlayer.identity), position: \(position)")
                self?.sendSetPositionCommand(to: activePlayer, position: position)
                return .success
            }
            Log.debug?.message("MPRIS::changePlaybackPositionCommand - invalid event type")
            return .commandFailed
        }
    }
    
    private func findActivePlayer() -> PlayerRemote? {
        Log.debug?.message("MPRIS::findActivePlayer() called")
        
        // First, check if we have a last active player and it's still valid (exists in players dictionary)
        if let lastPlayer = lastActivePlayer {
            Log.debug?.message("MPRIS::findActivePlayer() - checking lastActivePlayer: \(lastPlayer.identity)")
            // Make sure this player still exists in the dictionary
            if let devicePlayers = players[lastPlayer.device.id], devicePlayers.contains(where: { $0 === lastPlayer }) {
                Log.debug?.message("MPRIS::findActivePlayer() - returning lastActivePlayer: \(lastPlayer.identity)")
                return lastPlayer
            } else {
                Log.debug?.message("MPRIS::findActivePlayer() - lastActivePlayer no longer exists, clearing it")
                self.lastActivePlayer = nil
            }
        }
        
        // Next, look for a player that is currently playing
        for deviceID in players.keys {
            if let devicePlayers = players[deviceID] {
                for player in devicePlayers {
                    Log.debug?.message("MPRIS::findActivePlayer() - checking player: \(player.identity), isPlaying: \(player.isPlaying)")
                    if player.isPlaying {
                        Log.debug?.message("MPRIS::findActivePlayer() - found playing player: \(player.identity)")
                        self.lastActivePlayer = player  // Update lastActivePlayer
                        return player
                    }
                }
            }
        }
        
        // If no player is playing, return the first player
        for deviceID in players.keys {
            if let devicePlayers = players[deviceID], let player = devicePlayers.first {
                Log.debug?.message("MPRIS::findActivePlayer() - no playing player found, returning first player: \(player.identity)")
                return player
            }
        }
        
        Log.debug?.message("MPRIS::findActivePlayer() - no players found, returning nil")
        return nil
    }
    
    private func updateCommandCenterForActivePlayer(_ player: PlayerRemote) {
        // Update commands availability
        commandCenter.pauseCommand.isEnabled = player.canPause
        commandCenter.playCommand.isEnabled = player.canPlay
        commandCenter.togglePlayPauseCommand.isEnabled = player.canPause || player.canPlay
        commandCenter.nextTrackCommand.isEnabled = player.canGoNext
        commandCenter.previousTrackCommand.isEnabled = player.canGoPrevious
        commandCenter.changePlaybackPositionCommand.isEnabled = player.length > 0
    }
    
    // MARK: Private methods - Player Commands
    
    private func sendPlayPauseCommand(to player: PlayerRemote) {
        player.device.send(DataPacket.mprisRequestPacket(player: player.identity, action: "PlayPause"))
    }
    
    private func sendPlayCommand(to player: PlayerRemote) {
        player.device.send(DataPacket.mprisRequestPacket(player: player.identity, action: "Play"))
    }
    
    private func sendPauseCommand(to player: PlayerRemote) {
        player.device.send(DataPacket.mprisRequestPacket(player: player.identity, action: "Pause"))
    }
    
    private func sendNextCommand(to player: PlayerRemote) {
        player.device.send(DataPacket.mprisRequestPacket(player: player.identity, action: "Next"))
    }
    
    private func sendPreviousCommand(to player: PlayerRemote) {
        player.device.send(DataPacket.mprisRequestPacket(player: player.identity, action: "Previous"))
    }
    
    private func sendStopCommand(to player: PlayerRemote) {
        player.device.send(DataPacket.mprisRequestPacket(player: player.identity, action: "Stop"))
    }
    
    private func sendSetVolumeCommand(to player: PlayerRemote, volume: Int) {
        player.device.send(DataPacket.mprisSetVolumePacket(player: player.identity, volume: volume))
    }
    
    private func sendSeekCommand(to player: PlayerRemote, offset: Int) {
        player.device.send(DataPacket.mprisSeekPacket(player: player.identity, offset: offset))
    }
    
    private func sendSetPositionCommand(to player: PlayerRemote, position: Int) {
        let positionInMs = position * 1000
        Log.debug?.message("MPRIS::sendSetPositionCommand() - player: \(player.identity), position: \(position)s -> \(positionInMs)ms")
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
        Log.debug?.message("MPRIS::Starting album art download for player \(player) from \(albumArtUrl)")
        
        let downloadFileHash = getHashForAlbumArt(player: player, albumArtUrl: albumArtUrl)
        
        // Check if we already have this album art cached
        if let hash = downloadFileHash, let cachedFileURL = getCachedAlbumArt(hash: hash) {
            Log.debug?.message("MPRIS::Found cached album art for hash \(hash) at \(cachedFileURL)")
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
            Log.debug?.message("MPRIS::Album art download already in progress for \(albumArtUrl)")
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
            Log.debug?.message("MPRIS::Started download task for album art")
        } else {
            Log.error?.message("MPRIS::Failed to create download stream for album art")
        }
    }
    
    private func getHashForAlbumArt(player: String, albumArtUrl: String) -> String? {
        // Use MD5 hash like GSConnect for better cache compatibility
        let inputString = albumArtUrl // GSConnect uses just the URL for hashing
        guard let inputData = inputString.data(using: .utf8) else { return nil }
        
        var hash = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        inputData.withUnsafeBytes { bytes in
            CC_MD5(bytes.bindMemory(to: UInt8.self).baseAddress, CC_LONG(inputData.count), &hash)
        }
        
        return hash.map { String(format: "%02x", $0) }.joined()
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
                    Log.debug?.message("MPRIS::Successfully created download stream at: \(partFileURL.path)")
                    return (stream, partFileURL)
                } else {
                    Log.debug?.message("MPRIS::Stream failed to open with status: \(stream.streamStatus.rawValue)")
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
    
    // MARK: Cache Management
    
    private func cleanupOldCacheFiles() {
        let cacheDirectory = getCacheDirectory()
        
        do {
            let contents = try FileManager.default.contentsOfDirectory(at: cacheDirectory, 
                                                                      includingPropertiesForKeys: [.contentModificationDateKey], 
                                                                      options: [])
            
            let cutoffDate = Date().addingTimeInterval(-7 * 24 * 60 * 60) // 7 days ago
            
            for fileURL in contents {
                if let modificationDate = try fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   modificationDate < cutoffDate {
                    try FileManager.default.removeItem(at: fileURL)
                    Log.debug?.message("MPRIS::Cleaned up old cache file: \(fileURL.lastPathComponent)")
                }
            }
        } catch {
            Log.error?.message("MPRIS::Failed to cleanup old cache files: \(error)")
        }
    }
    
    private func logCacheStats() {
        let cacheDirectory = getCacheDirectory()
        
        do {
            let contents = try FileManager.default.contentsOfDirectory(at: cacheDirectory, 
                                                                      includingPropertiesForKeys: [.fileSizeKey], 
                                                                      options: [])
            
            let totalSize = contents.compactMap { url -> Int? in
                guard let resourceValues = try? url.resourceValues(forKeys: [.fileSizeKey]),
                      let fileSize = resourceValues.fileSize else {
                    return nil
                }
                return fileSize
            }.reduce(0, +)
            
            Log.debug?.message("MPRIS::Cache stats - Files: \(contents.count), Total size: \(totalSize) bytes")
        } catch {
            Log.debug?.message("MPRIS::Could not get cache stats: \(error)")
        }
    }
}

// MARK: - Player Remote Class

class PlayerRemote: NSObject {
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
        Log.debug?.message("MPRIS::PlayerRemote updating album art for \(identity) from \(fileURL.path)")
        
        if let image = NSImage(contentsOf: fileURL) {
            self.albumArtImage = image
            Log.debug?.message("MPRIS::PlayerRemote successfully loaded album art image (\(image.size.width)x\(image.size.height))")
        } else {
            Log.error?.message("MPRIS::PlayerRemote failed to load album art image from \(fileURL.path)")
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
            Log.debug?.message("MPRIS::PlayerRemote set artwork for \(identity)")
        } else {
            nowPlayingInfo.removeValue(forKey: MPMediaItemPropertyArtwork)
        }
        
        // Add device and player info for identification
        nowPlayingInfo["deviceName"] = device.name
        nowPlayingInfo["playerName"] = identity
        
        nowPlayingInfoCenter.nowPlayingInfo = nowPlayingInfo
        Log.debug?.message("MPRIS::PlayerRemote updated now playing info for \(identity)")
    }
    
    func cleanup() {
        // Only clear now playing info when this player is being removed from the device
        isPlaying = false
        nowPlayingInfoCenter.nowPlayingInfo = nil
    }
}

// MARK: - Media Remote Player (Real Implementation)

class MediaRemotePlayer: PlayerLocal {
    
    // MediaRemote framework functions
    private var mediaRemoteBundle: CFBundle?
    private var MRMediaRemoteGetNowPlayingInfo: MRMediaRemoteGetNowPlayingInfoFunction?
    private var MRNowPlayingClientGetBundleIdentifier: MRNowPlayingClientGetBundleIdentifierFunction?
    private var MRMediaRemoteSetCanBeNowPlayingApplication: MRMediaRemoteSetCanBeNowPlayingApplicationFunction?
    private var MRMediaRemoteRegisterForNowPlayingNotifications: MRMediaRemoteRegisterForNowPlayingNotificationsFunction?
    private var MRMediaRemoteUnregisterForNowPlayingNotifications: MRMediaRemoteUnregisterForNowPlayingNotificationsFunction?
    private var MRMediaRemoteSendCommand: MRMediaRemoteSendCommandFunction?
    
    // Function type definitions
    typealias MRMediaRemoteGetNowPlayingInfoFunction = @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void
    typealias MRNowPlayingClientGetBundleIdentifierFunction = @convention(c) (AnyObject?) -> String
    typealias MRMediaRemoteSetCanBeNowPlayingApplicationFunction = @convention(c) (Bool) -> Void
    typealias MRMediaRemoteRegisterForNowPlayingNotificationsFunction = @convention(c) (DispatchQueue) -> Void
    typealias MRMediaRemoteUnregisterForNowPlayingNotificationsFunction = @convention(c) (DispatchQueue) -> Void
    typealias MRMediaRemoteSendCommandFunction = @convention(c) (UInt32, [String: Any]?) -> Bool
    
    // MediaRemote command constants
    private enum MRCommand: UInt32 {
        case play = 0
        case pause = 1
        case togglePlayPause = 2
        case stop = 3
        case nextTrack = 4
        case previousTrack = 5
        case seekForward = 7
        case seekBackward = 8
    }
    
    // Current app bundle identifier and name
    private var currentAppBundleId: String = ""
    private var currentAppName: String = ""
    
    // Track if MediaRemote framework is available
    var isMediaRemoteAvailable: Bool {
        return mediaRemoteBundle != nil && MRMediaRemoteGetNowPlayingInfo != nil
    }
    
    override init(identity: String = "macOS.NowPlaying") {
        super.init(identity: identity)
        
        // Load MediaRemote framework
        loadMediaRemoteFramework()
        
        // Register for now playing notifications
        registerForNotifications()
        
        // Also try to listen to MPNowPlayingInfoCenter as a fallback
        setupMPNowPlayingInfoCenterFallback()
        
        // Initial fetch of now playing info
        fetchNowPlayingInfo()
        
        // Set up periodic refresh with shorter intervals to try to catch changes
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.fetchNowPlayingInfo()
        }
        
        // Also try to get info from MPNowPlayingInfoCenter periodically
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkMPNowPlayingInfoCenter()
        }
    }
    
    private func setupMPNowPlayingInfoCenterFallback() {
        // Try to get information from the system's MPNowPlayingInfoCenter
        // This might have different permission requirements
        Log.debug?.message("MediaRemotePlayer: Setting up MPNowPlayingInfoCenter fallback")
    }
    
    private func checkMPNowPlayingInfoCenter() {
        // Try to get now playing info from MPNowPlayingInfoCenter as a fallback
        let infoCenter = MPNowPlayingInfoCenter.default()
        if let nowPlayingInfo = infoCenter.nowPlayingInfo, !nowPlayingInfo.isEmpty {
            Log.debug?.message("MediaRemotePlayer: Got info from MPNowPlayingInfoCenter: \(nowPlayingInfo.keys)")
            updateFromMPNowPlayingInfo(nowPlayingInfo)
        }
    }
    
    private func updateFromMPNowPlayingInfo(_ nowPlayingInfo: [String: Any]) {
        var hasChanges = false
        
        if let newTitle = nowPlayingInfo[MPMediaItemPropertyTitle] as? String, newTitle != title {
            title = newTitle
            hasChanges = true
            Log.debug?.message("MediaRemotePlayer: Updated title from MPNowPlayingInfoCenter: \(title)")
        }
        
        if let newArtist = nowPlayingInfo[MPMediaItemPropertyArtist] as? String, newArtist != artist {
            artist = newArtist
            hasChanges = true
            Log.debug?.message("MediaRemotePlayer: Updated artist from MPNowPlayingInfoCenter: \(artist)")
        }
        
        if let newAlbum = nowPlayingInfo[MPMediaItemPropertyAlbumTitle] as? String, newAlbum != album {
            album = newAlbum
            hasChanges = true
            Log.debug?.message("MediaRemotePlayer: Updated album from MPNowPlayingInfoCenter: \(album)")
        }
        
        if let duration = nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] as? TimeInterval {
            let newLength = Int(duration)
            if newLength != length {
                length = newLength
                hasChanges = true
                Log.debug?.message("MediaRemotePlayer: Updated length from MPNowPlayingInfoCenter: \(length)s")
            }
        }
        
        if let elapsed = nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? TimeInterval {
            let newPosition = Int(elapsed)
            if newPosition != position {
                position = newPosition
                hasChanges = true
                Log.debug?.message("MediaRemotePlayer: Updated position from MPNowPlayingInfoCenter: \(position)s")
            }
        }
        
        if let playbackRate = nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] as? Double {
            let newIsPlaying = playbackRate > 0
            if newIsPlaying != isPlaying {
                isPlaying = newIsPlaying
                hasChanges = true
                Log.debug?.message("MediaRemotePlayer: Updated playing state from MPNowPlayingInfoCenter: \(isPlaying)")
            }
        }
        
        if hasChanges {
            lastUpdateTime = Date()
            onStateChanged?()
        }
    }
    
    deinit {
        unregisterFromNotifications()
    }
    
    private func loadMediaRemoteFramework() {
        // Load MediaRemote framework
        guard let bundle = CFBundleCreate(kCFAllocatorDefault, 
                                        NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")) else {
            Log.error?.message("MediaRemotePlayer: Failed to load MediaRemote framework")
            return
        }
        
        mediaRemoteBundle = bundle
        
        // Get function pointers
        if let getNowPlayingPointer = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteGetNowPlayingInfo" as CFString) {
            MRMediaRemoteGetNowPlayingInfo = unsafeBitCast(getNowPlayingPointer, to: MRMediaRemoteGetNowPlayingInfoFunction.self)
        }
        
        if let getBundleIdPointer = CFBundleGetFunctionPointerForName(bundle, "MRNowPlayingClientGetBundleIdentifier" as CFString) {
            MRNowPlayingClientGetBundleIdentifier = unsafeBitCast(getBundleIdPointer, to: MRNowPlayingClientGetBundleIdentifierFunction.self)
        }
        
        if let setCanBeNowPlayingPointer = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteSetCanBeNowPlayingApplication" as CFString) {
            MRMediaRemoteSetCanBeNowPlayingApplication = unsafeBitCast(setCanBeNowPlayingPointer, to: MRMediaRemoteSetCanBeNowPlayingApplicationFunction.self)
        }
        
        if let registerNotificationsPointer = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteRegisterForNowPlayingNotifications" as CFString) {
            MRMediaRemoteRegisterForNowPlayingNotifications = unsafeBitCast(registerNotificationsPointer, to: MRMediaRemoteRegisterForNowPlayingNotificationsFunction.self)
        }
        
        if let unregisterNotificationsPointer = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteUnregisterForNowPlayingNotifications" as CFString) {
            MRMediaRemoteUnregisterForNowPlayingNotifications = unsafeBitCast(unregisterNotificationsPointer, to: MRMediaRemoteUnregisterForNowPlayingNotificationsFunction.self)
        }
        
        if let sendCommandPointer = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteSendCommand" as CFString) {
            MRMediaRemoteSendCommand = unsafeBitCast(sendCommandPointer, to: MRMediaRemoteSendCommandFunction.self)
        }
        
        Log.debug?.message("MediaRemotePlayer: Successfully loaded MediaRemote framework functions")
        Log.info?.message("MediaRemotePlayer: Note - MediaRemote control may require additional entitlements or code signing for full functionality")
    }
    
    private func registerForNotifications() {
        guard let registerFunc = MRMediaRemoteRegisterForNowPlayingNotifications else { 
            Log.warning?.message("MediaRemotePlayer: MRMediaRemoteRegisterForNowPlayingNotifications function not available")
            return 
        }
        
        // Register for notifications on main queue
        registerFunc(DispatchQueue.main)
        
        // Listen for now playing info changed notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(nowPlayingInfoChanged),
            name: NSNotification.Name("kMRMediaRemoteNowPlayingInfoDidChangeNotification"),
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(nowPlayingInfoChanged),
            name: NSNotification.Name("kMRMediaRemoteNowPlayingApplicationDidChangeNotification"),
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(nowPlayingInfoChanged),
            name: NSNotification.Name("kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification"),
            object: nil
        )
        
        Log.debug?.message("MediaRemotePlayer: Registered for MediaRemote notifications")
    }
    
    private func unregisterFromNotifications() {
        guard let unregisterFunc = MRMediaRemoteUnregisterForNowPlayingNotifications else { return }
        
        unregisterFunc(DispatchQueue.main)
        NotificationCenter.default.removeObserver(self)
        
        Log.debug?.message("MediaRemotePlayer: Unregistered from MediaRemote notifications")
    }
    
    @objc private func nowPlayingInfoChanged() {
        Log.debug?.message("MediaRemotePlayer: Now playing info changed notification received")
        fetchNowPlayingInfo()
    }
    
    private func fetchNowPlayingInfo() {
        guard let getNowPlayingFunc = MRMediaRemoteGetNowPlayingInfo else { 
            Log.warning?.message("MediaRemotePlayer: MRMediaRemoteGetNowPlayingInfo function not available")
            return 
        }
        
        Log.debug?.message("MediaRemotePlayer: Fetching now playing info...")
        
        getNowPlayingFunc(DispatchQueue.main) { [weak self] information in
            Log.debug?.message("MediaRemotePlayer: Received now playing info callback with \(information.count) keys")
            if information.isEmpty {
                Log.debug?.message("MediaRemotePlayer: No media information available - likely permission issue or no active player")
                // Try to set a basic state indicating we're ready but have no media info
                self?.updateBasicPlayerState()
            } else {
                Log.debug?.message("MediaRemotePlayer: Processing media information: \(Array(information.keys))")
                self?.updateFromNowPlayingInfo(information)
            }
        }
    }
    
    private func updateBasicPlayerState() {
        // Set basic player state when we can't get media info but want to show the player is available
        if artist.isEmpty && title.isEmpty {
            // Only update if we don't already have any info
            artist = ""
            title = ""
            album = ""
            length = 0
            position = 0
            isPlaying = false
            lastUpdateTime = Date()
            Log.debug?.message("MediaRemotePlayer: Set basic player state - ready but no media info available")
        }
    }
    
    private func updateFromNowPlayingInfo(_ information: [String: Any]) {
        Log.debug?.message("MediaRemotePlayer: Updating from now playing info with \(information.count) keys")
        
        // Log available keys for debugging
        if information.isEmpty {
            Log.debug?.message("MediaRemotePlayer: No now playing information available")
            return
        }
        
        var hasChanges = false
        
        // Update basic track info
        if let newArtist = information["kMRMediaRemoteNowPlayingInfoArtist"] as? String, newArtist != artist {
            artist = newArtist.isEmpty ? "" : newArtist
            hasChanges = true
            Log.debug?.message("MediaRemotePlayer: Updated artist: \(artist)")
        }
        
        if let newTitle = information["kMRMediaRemoteNowPlayingInfoTitle"] as? String, newTitle != title {
            title = newTitle.isEmpty ? "" : newTitle
            hasChanges = true
            Log.debug?.message("MediaRemotePlayer: Updated title: \(title)")
        }
        
        if let newAlbum = information["kMRMediaRemoteNowPlayingInfoAlbum"] as? String, newAlbum != album {
            album = newAlbum.isEmpty ? "" : newAlbum
            hasChanges = true
            Log.debug?.message("MediaRemotePlayer: Updated album: \(album)")
        }
        
        // Update duration
        if let duration = information["kMRMediaRemoteNowPlayingInfoDuration"] as? Double {
            let newLength = Int(duration)
            if newLength != length {
                length = newLength
                hasChanges = true
                Log.debug?.message("MediaRemotePlayer: Updated length: \(length)s")
            }
        }
        
        // Update position
        if let elapsed = information["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? Double {
            let newPosition = Int(elapsed)
            if newPosition != position {
                position = newPosition
                hasChanges = true
                Log.debug?.message("MediaRemotePlayer: Updated position: \(position)s")
            }
        }
        
        // Update playback state
        if let playbackRate = information["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double {
            let newIsPlaying = playbackRate > 0
            if newIsPlaying != isPlaying {
                isPlaying = newIsPlaying
                hasChanges = true
                Log.debug?.message("MediaRemotePlayer: Updated playing state: \(isPlaying)")
            }
        }
        
        // Get app bundle identifier
        if let clientPropertiesData = information["kMRMediaRemoteNowPlayingInfoClientPropertiesData"] {
            if let bundleId = getBundleIdentifierFromClientProperties(clientPropertiesData) {
                if currentAppBundleId != bundleId {
                    currentAppBundleId = bundleId
                    currentAppName = getAppNameFromBundleId(bundleId)
                    Log.debug?.message("MediaRemotePlayer: Now playing from app: \(bundleId) (\(currentAppName))")
                    hasChanges = true
                }
            }
        } else if !currentAppBundleId.isEmpty {
            // No app is currently playing
            currentAppBundleId = ""
            currentAppName = ""
            hasChanges = true
            Log.debug?.message("MediaRemotePlayer: No app currently playing")
        }
        
        // Update artwork URL if available
        if information["kMRMediaRemoteNowPlayingInfoArtworkData"] != nil {
            // We have artwork data - could save it and provide a local URL
            // For now, just indicate that artwork is available
            if albumArtUrl.isEmpty {
                albumArtUrl = "mediaremote://artwork/\(currentAppBundleId)"
                hasChanges = true
            }
        } else if !albumArtUrl.isEmpty {
            albumArtUrl = ""
            hasChanges = true
        }
        
        if hasChanges {
            lastUpdateTime = Date()
            Log.debug?.message("MediaRemotePlayer: Updated track info: \(artist) - \(title) (\(album)) playing: \(isPlaying)")
        }
    }
    
    private func getBundleIdentifierFromClientProperties(_ clientPropertiesData: Any) -> String? {
        guard let getBundleIdFunc = MRNowPlayingClientGetBundleIdentifier else { return nil }
        
        // Use the complex method from the example to get bundle identifier
        let _MRNowPlayingClientProtobuf: AnyClass? = NSClassFromString("_MRNowPlayingClientProtobuf")
        guard let protobufClass = _MRNowPlayingClientProtobuf else { return nil }
        
        let handle: UnsafeMutableRawPointer! = dlopen("/usr/lib/libobjc.A.dylib", RTLD_NOW)
        guard handle != nil else { return nil }
        
        defer { dlclose(handle) }
        
        let object = unsafeBitCast(dlsym(handle, "objc_msgSend"), 
                                 to: (@convention(c)(AnyClass?, Selector?) -> AnyObject).self)(protobufClass, Selector("alloc"))
        
        unsafeBitCast(dlsym(handle, "objc_msgSend"), 
                     to: (@convention(c)(AnyObject?, Selector?, Any?) -> Void).self)(object, Selector("initWithData:"), clientPropertiesData)
        
        return getBundleIdFunc(object)
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
            "fm.last.desktop": "Last.fm",
            "com.apple.iWork.Keynote": "Keynote",
            "com.microsoft.Powerpoint": "PowerPoint",
            "us.zoom.xos": "Zoom",
            "com.microsoft.teams": "Teams"
        ]
        
        if let appName = knownApps[bundleId] {
            Log.debug?.message("MediaRemotePlayer: Found known app name: \(appName) for bundle: \(bundleId)")
            return appName
        }
        
        // Try to get the app name from the bundle identifier
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId),
           let bundle = Bundle(url: appURL),
           let displayName = bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String ?? bundle.infoDictionary?["CFBundleDisplayName"] as? String {
            Log.debug?.message("MediaRemotePlayer: Found display name: \(displayName) for bundle: \(bundleId)")
            return displayName
        }
        
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId),
           let bundle = Bundle(url: appURL),
           let bundleName = bundle.localizedInfoDictionary?["CFBundleName"] as? String ?? bundle.infoDictionary?["CFBundleName"] as? String {
            Log.debug?.message("MediaRemotePlayer: Found bundle name: \(bundleName) for bundle: \(bundleId)")
            return bundleName
        }
        
        // Fall back to extracting from bundle ID
        let components = bundleId.split(separator: ".")
        if let lastComponent = components.last {
            let appName = String(lastComponent).capitalized
            Log.debug?.message("MediaRemotePlayer: Using extracted name: \(appName) for bundle: \(bundleId)")
            return appName
        }
        
        Log.debug?.message("MediaRemotePlayer: Could not determine app name for bundle: \(bundleId)")
        return "Unknown App"
    }
    
    func getCurrentAppName() -> String {
        return currentAppName
    }
    
    override func updateIdentity(_ newIdentity: String) {
        identity = newIdentity
        Log.debug?.message("MediaRemotePlayer: Identity updated to: \(newIdentity)")
    }
    
    // MARK: - Player Controls (Override to use MediaRemote)
    
    override func play() {
        Log.debug?.message("MediaRemotePlayer: Play command")
        sendMediaRemoteCommand(.play)
    }
    
    override func pause() {
        Log.debug?.message("MediaRemotePlayer: Pause command")
        sendMediaRemoteCommand(.pause)
    }
    
    override func playPause() {
        Log.debug?.message("MediaRemotePlayer: PlayPause command")
        sendMediaRemoteCommand(.togglePlayPause)
    }
    
    override func next() {
        Log.debug?.message("MediaRemotePlayer: Next command")
        sendMediaRemoteCommand(.nextTrack)
    }
    
    override func previous() {
        Log.debug?.message("MediaRemotePlayer: Previous command")
        sendMediaRemoteCommand(.previousTrack)
    }
    
    override func stop() {
        Log.debug?.message("MediaRemotePlayer: Stop command")
        sendMediaRemoteCommand(.stop)
    }
    
    override func seek(_ offsetMs: Int) {
        Log.debug?.message("MediaRemotePlayer: Seek by \(offsetMs)ms")
        // MediaRemote doesn't have a direct seek offset, but we can try to set the position
        let newPosition = max(0, position + (offsetMs / 1000))
        setPosition(newPosition * 1000)
    }
    
    override func setPosition(_ positionMs: Int) {
        Log.debug?.message("MediaRemotePlayer: Set position to \(positionMs)ms")
        // MediaRemote position setting requires a different approach
        // For now, just update our local position and hope the app handles it
        position = positionMs / 1000
        lastUpdateTime = Date()
        onStateChanged?()
    }
    
    override func setVolume(_ newVolume: Int) {
        Log.debug?.message("MediaRemotePlayer: Set volume to \(newVolume)")
        // MediaRemote volume control would require additional functions
        // For now, just update local state
        volume = max(0, min(100, newVolume))
        lastUpdateTime = Date()
        onStateChanged?()
    }
    
    private func sendMediaRemoteCommand(_ command: MRCommand) {
        guard let sendCommandFunc = MRMediaRemoteSendCommand else {
            Log.error?.message("MediaRemotePlayer: MRMediaRemoteSendCommand function not available")
            return
        }
        
        Log.debug?.message("MediaRemotePlayer: Attempting to send command \(command)")
        let success = sendCommandFunc(command.rawValue, nil)
        
        if success {
            Log.debug?.message("MediaRemotePlayer: Successfully sent command \(command)")
            
            // Force trigger state change callback to notify connected devices
            onStateChanged?()
            
            // Try to fetch updated info after successful command with multiple attempts
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.fetchNowPlayingInfo()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.fetchNowPlayingInfo()
            }
        } else {
            Log.warning?.message("MediaRemotePlayer: Failed to send command \(command) - likely due to insufficient permissions or no active media player")
            Log.warning?.message("MediaRemotePlayer: This may indicate that Soduto needs additional entitlements or the app needs to be code-signed for MediaRemote access")
        }
    }
    
    // Override state method to include current app info and indicate command capability
    override func getCurrentState() -> [String: Any] {
        var state = super.getCurrentState()
        
        // Add app bundle identifier and name if available
        if !currentAppBundleId.isEmpty {
            state["nowPlayingApp"] = currentAppBundleId
            state["appName"] = currentAppName
        }
        
        // Indicate that we support MediaRemote commands even if we don't have media info
        state["supportsMediaRemoteCommands"] = true
        
        // If we don't have any media info, indicate that controls are still available
        if artist.isEmpty && title.isEmpty && length == 0 {
            state["playerStatus"] = "ready_no_media"
            state["statusMessage"] = "Media controls available (no active media)"
            
            // If we have an app name, show it in the status
            if !currentAppName.isEmpty {
                state["statusMessage"] = "\(currentAppName) media controls available (no active media)"
            }
        }
        
        return state
    }
}

/// Local player for testing MPRIS functionality
/// This represents a media player running on the Mac that can be controlled from remote devices
class PlayerLocal: NSObject {
    
    // Player identity and metadata
    private(set) var identity: String
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
    
    init(identity: String = "Player") {
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
        Log.debug?.message("PlayerLocal: Identity updated to: \(newIdentity)")
    }
    
    // MARK: - State Information
    
    /// Get current player state as a dictionary for sending in MPRIS packets
    func getCurrentState() -> [String: Any] {
        return [
            "player": identity,
            "pos": position,
            "isPlaying": isPlaying,
            "canPause": canPause,
            "canPlay": canPlay,
            "canGoNext": canGoNext,
            "canGoPrevious": canGoPrevious,
            "canSeek": canSeek,
            "loopStatus": loopStatus,
            "shuffle": shuffle,
            "albumArtUrl": albumArtUrl,
            "length": length,
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
