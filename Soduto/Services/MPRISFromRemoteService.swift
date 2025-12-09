//
//  MPRISFromRemoteService.swift
//  Soduto
//
//  Created by Sidevesh on 2025-12-08.
//  Copyright © 2025 Soduto. All rights reserved.
//
//  Handles receiving remote device media status and controlling it from Mac
//  Receives kdeconnect.mpris packets with remote player updates

import Foundation
import Cocoa
import CleanroomLogger
import MediaPlayer
import CommonCrypto

// MARK: - Remote Player Class

/// Represents a media player on a remote device that we can control
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

// MARK: - DataPacket MPRIS Extensions (FromRemote specific)

fileprivate extension DataPacket {
    
    // MARK: Validation
    
    func validateMprisType() throws {
        guard self.isMprisPacket else { throw DataPacket.MprisError.wrongType }
    }
    
    // MARK: Packet Creation - Request Packets to Send to Remote
    
    static func mprisRequestPlayerListPacket() -> DataPacket {
        return DataPacket(type: mprisRequestPacketType, body: [
            DataPacket.MprisProperty.requestPlayerList.rawValue: true as AnyObject
        ])
    }
    
    static func mprisRequestInfoPacket(player: String) -> DataPacket {
        return DataPacket(type: mprisRequestPacketType, body: [
            DataPacket.MprisProperty.player.rawValue: player as AnyObject,
            DataPacket.MprisProperty.requestNowPlaying.rawValue: true as AnyObject,
            DataPacket.MprisProperty.requestVolume.rawValue: true as AnyObject
        ])
    }
    
    static func mprisRequestAlbumArtPacket(player: String, albumArtUrl: String) -> DataPacket {
        return DataPacket(type: mprisRequestPacketType, body: [
            DataPacket.MprisProperty.player.rawValue: player as AnyObject,
            DataPacket.MprisProperty.albumArtUrl.rawValue: albumArtUrl as AnyObject
        ])
    }
    
    static func mprisRequestPacket(player: String, action: String) -> DataPacket {
        return DataPacket(type: mprisRequestPacketType, body: [
            DataPacket.MprisProperty.player.rawValue: player as AnyObject,
            DataPacket.MprisProperty.action.rawValue: action as AnyObject
        ])
    }
    
    static func mprisSetVolumePacket(player: String, volume: Int) -> DataPacket {
        return DataPacket(type: mprisRequestPacketType, body: [
            DataPacket.MprisProperty.player.rawValue: player as AnyObject,
            "setVolume": volume as AnyObject
        ])
    }
    
    static func mprisSeekPacket(player: String, offset: Int) -> DataPacket {
        return DataPacket(type: mprisRequestPacketType, body: [
            DataPacket.MprisProperty.player.rawValue: player as AnyObject,
            DataPacket.MprisProperty.Seek.rawValue: offset as AnyObject
        ])
    }
    
    static func mprisSetPositionPacket(player: String, position: Int) -> DataPacket {
        return DataPacket(type: mprisRequestPacketType, body: [
            DataPacket.MprisProperty.player.rawValue: player as AnyObject,
            DataPacket.MprisProperty.SetPosition.rawValue: position as AnyObject
        ])
    }
    
    // MARK: Update Packet Parsing - From Remote
    
    func getPlayer() throws -> String? {
        try validateMprisType()
        guard body.keys.contains(DataPacket.MprisProperty.player.rawValue) else { return nil }
        guard let value = body[DataPacket.MprisProperty.player.rawValue] as? String else { throw DataPacket.MprisError.invalidPlayer }
        return value
    }
    
    func getPlayerList() throws -> [String]? {
        try validateMprisType()
        guard body.keys.contains(DataPacket.MprisProperty.playerList.rawValue) else { return nil }
        guard let value = body[DataPacket.MprisProperty.playerList.rawValue] as? [String] else { throw DataPacket.MprisError.invalidPlayerList }
        return value
    }
    
    func getAlbumArtUrl() throws -> String? {
        try validateMprisType()
        guard body.keys.contains(DataPacket.MprisProperty.albumArtUrl.rawValue) else { return nil }
        guard let value = body[DataPacket.MprisProperty.albumArtUrl.rawValue] as? String else { throw DataPacket.MprisError.invalidAlbumArtUrl }
        return value
    }
    
    func getIsPlaying() throws -> Bool? {
        try validateMprisType()
        guard body.keys.contains(DataPacket.MprisProperty.isPlaying.rawValue) else { return nil }
        guard let value = body[DataPacket.MprisProperty.isPlaying.rawValue] as? Bool else { throw DataPacket.MprisError.invalidIsPlaying }
        return value
    }
    
    func getCanPause() throws -> Bool? {
        try validateMprisType()
        guard body.keys.contains(DataPacket.MprisProperty.canPause.rawValue) else { return nil }
        guard let value = body[DataPacket.MprisProperty.canPause.rawValue] as? Bool else { throw DataPacket.MprisError.invalidCanPause }
        return value
    }
    
    func getCanPlay() throws -> Bool? {
        try validateMprisType()
        guard body.keys.contains(DataPacket.MprisProperty.canPlay.rawValue) else { return nil }
        guard let value = body[DataPacket.MprisProperty.canPlay.rawValue] as? Bool else { throw DataPacket.MprisError.invalidCanPlay }
        return value
    }
    
    func getCanGoNext() throws -> Bool? {
        try validateMprisType()
        guard body.keys.contains(DataPacket.MprisProperty.canGoNext.rawValue) else { return nil }
        guard let value = body[DataPacket.MprisProperty.canGoNext.rawValue] as? Bool else { throw DataPacket.MprisError.invalidCanGoNext }
        return value
    }
    
    func getCanGoPrevious() throws -> Bool? {
        try validateMprisType()
        guard body.keys.contains(DataPacket.MprisProperty.canGoPrevious.rawValue) else { return nil }
        guard let value = body[DataPacket.MprisProperty.canGoPrevious.rawValue] as? Bool else { throw DataPacket.MprisError.invalidCanGoPrevious }
        return value
    }
    
    func getPosition() throws -> Int? {
        try validateMprisType()
        guard body.keys.contains(DataPacket.MprisProperty.pos.rawValue) else { return nil }
        guard let value = body[DataPacket.MprisProperty.pos.rawValue] as? Int else { throw DataPacket.MprisError.invalidPosition }
        return value
    }
    
    func getLength() throws -> Int? {
        try validateMprisType()
        guard body.keys.contains(DataPacket.MprisProperty.length.rawValue) else { return nil }
        guard let value = body[DataPacket.MprisProperty.length.rawValue] as? Int else { throw DataPacket.MprisError.invalidLength }
        return value
    }
    
    func getArtist() throws -> String? {
        try validateMprisType()
        guard body.keys.contains(DataPacket.MprisProperty.artist.rawValue) else { return nil }
        guard let value = body[DataPacket.MprisProperty.artist.rawValue] as? String else { throw DataPacket.MprisError.invalidArtist }
        return value
    }
    
    func getTitle() throws -> String? {
        try validateMprisType()
        guard body.keys.contains(DataPacket.MprisProperty.title.rawValue) else { return nil }
        guard let value = body[DataPacket.MprisProperty.title.rawValue] as? String else { throw DataPacket.MprisError.invalidTitle }
        return value
    }
    
    func getAlbum() throws -> String? {
        try validateMprisType()
        guard body.keys.contains(DataPacket.MprisProperty.album.rawValue) else { return nil }
        guard let value = body[DataPacket.MprisProperty.album.rawValue] as? String else { throw DataPacket.MprisError.invalidAlbum }
        return value
    }
    
    func getVolume() throws -> Int? {
        try validateMprisType()
        guard body.keys.contains(DataPacket.MprisProperty.volume.rawValue) else { return nil }
        guard let value = body[DataPacket.MprisProperty.volume.rawValue] as? Int else { throw DataPacket.MprisError.invalidVolume }
        return value
    }
    
    func getTransferringAlbumArt() throws -> Bool? {
        try validateMprisType()
        guard body.keys.contains(DataPacket.MprisProperty.transferringAlbumArt.rawValue) else { return nil }
        guard let value = body[DataPacket.MprisProperty.transferringAlbumArt.rawValue] as? Bool else { 
            throw DataPacket.MprisError.invalidTransferringAlbumArt 
        }
        return value
    }
}

// MARK: - MPRIS From Remote Service

/// Service that receives remote device media status and allows Mac control
/// Handles kdeconnect.mpris packets from remote devices
public class MPRISFromRemoteService: Service, DownloadTaskDelegate {
    
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
    
    enum ActionId: ServiceAction.Id {
        case refresh
    }
    
    // MARK: Service properties
    
    public static let serviceId: Service.Id = "com.soduto.services.mpris.fromremote"
    
    public let incomingCapabilities = Set<Service.Capability>([ DataPacket.mprisPacketType ])
    public let outgoingCapabilities = Set<Service.Capability>([ DataPacket.mprisRequestPacketType ])
    
    private var albumArtDownloadInfos: [DownloadInfo] = []
    private var downloadedAlbumArtFileURLByPlayerIdentity: [String: URL] = [:]
    private var cachedDownloadedAlbumArtFileURLByHash: [String: URL] = [:]
    
    /// Available remote players grouped by device
    @Published private var players: [String: [RemotePlayer]] = [:]
    /// Keeps track of the last player that was playing
    private var lastActivePlayer: RemotePlayer? = nil
    private var commandCenter = MPRemoteCommandCenter.shared()
    
    // MARK: Initialization
    
    public init() {
        setupCommandCenter()
    }
    
    // MARK: Service methods
    
    public func handleDataPacket(_ dataPacket: DataPacket, fromDevice device: Device, onConnection connection: Connection) -> Bool {
        
        guard dataPacket.isMprisPacket else { return false }
                
        // Handle incoming player updates from remote devices
        return handleMprisUpdate(dataPacket, fromDevice: device, onConnection: connection)
    }
    
    public func setup(for device: Device) {
        // Request remote player list
        requestPlayerList(from: device)
    }
    
    public func cleanup(for device: Device) {
        // Remove players for this device
        if let devicePlayers = players.removeValue(forKey: device.id) {
            for player in devicePlayers {
                player.cleanup()
            }
        }
        
        // Cancel any ongoing album art downloads for this device
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
        guard device.outgoingCapabilities.contains(DataPacket.mprisPacketType) else { 
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
