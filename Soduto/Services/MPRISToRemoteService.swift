//
//  MPRISToRemoteService.swift
//  Soduto
//
//  Created by Sidevesh on 2025-12-08.
//  Copyright © 2025 Soduto. All rights reserved.
//
//  Handles sending local Mac media status to remote devices
//  Receives kdeconnect.mpris.request packets and responds with local player information

import Foundation
import Cocoa
import CleanroomLogger
import MediaPlayer
import CommonCrypto

// MARK: - Local Player Base Class

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

// MARK: - DataPacket MPRIS Extensions

// MARK: - DataPacket MPRIS Extensions (Base)

public extension DataPacket {
    
    // MARK: Types
    
    enum MprisError: Error {
        case wrongType
        case invalidPlayer
        case invalidPlayerList
        case invalidAlbumArtUrl
        case invalidAction
        case invalidSetVolume
        case invalidSetLoopStatus
        case invalidSetShuffle
        case invalidSeek
        case invalidSetPosition
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
    }
    
    enum MprisProperty: String {
        case playerList = "playerList"
        case player = "player"
        case albumArtUrl = "albumArtUrl"
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
        case volume = "volume"
    }
    
    // MARK: Properties
    
    static let mprisPacketType = "kdeconnect.mpris"
    static let mprisRequestPacketType = "kdeconnect.mpris.request"
    
    var isMprisPacket: Bool { return self.type == DataPacket.mprisPacketType }
    var isMprisRequestPacket: Bool { return self.type == DataPacket.mprisRequestPacketType }
}

// MARK: - DataPacket MPRIS Extensions (ToRemote specific)

fileprivate extension DataPacket {
    
    // MARK: Validation
    
    func validateMprisType() throws {
        guard self.isMprisRequestPacket else { throw MprisError.wrongType }
    }
    
    // MARK: Request Packet Parsing
    
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
    
    func getPlayer() throws -> String? {
        try validateMprisType()
        guard body.keys.contains(MprisProperty.player.rawValue) else { return nil }
        guard let value = body[MprisProperty.player.rawValue] as? String else { throw MprisError.invalidPlayer }
        return value
    }
    
    func getAlbumArtUrl() throws -> String? {
        try validateMprisType()
        guard body.keys.contains(MprisProperty.albumArtUrl.rawValue) else { return nil }
        guard let value = body[MprisProperty.albumArtUrl.rawValue] as? String else { throw MprisError.invalidAlbumArtUrl }
        return value
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
}

// MARK: - MPRIS To Remote Service

/// Service that sends local Mac media status to remote devices
/// Handles kdeconnect.mpris.request packets from remote devices
public class MPRISToRemoteService: Service {
    
    // MARK: Service properties
    
    public static let serviceId: Service.Id = "com.soduto.services.mpris.toremote"
    
    public let incomingCapabilities = Set<Service.Capability>([ DataPacket.mprisRequestPacketType ])
    public let outgoingCapabilities = Set<Service.Capability>([ DataPacket.mprisPacketType ])
    
    /// Local media controller - handles local media players that can be controlled by remote devices
    private var localMediaController = LocalMediaController()
    
    enum ActionId: ServiceAction.Id {
        case refresh
    }
    
    // MARK: Initialization
    
    public init() {
    }
    
    // MARK: Service methods
    
    public func handleDataPacket(_ dataPacket: DataPacket, fromDevice device: Device, onConnection connection: Connection) -> Bool {
        
        guard dataPacket.isMprisRequestPacket else { return false }
        
        return handleMprisRequest(dataPacket, fromDevice: device, onConnection: connection)
    }
    
    public func setup(for device: Device) {
        // Track connected devices
        localMediaController.addConnectedDevice(device)
        
        // Send our local player list after a small delay to ensure the device is ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.localMediaController.sendPlayerList(to: device)
        }
    }
    
    public func cleanup(for device: Device) {
        // Remove from connected devices
        localMediaController.removeConnectedDevice(device)
    }
    
    public func actions(for device: Device) -> [ServiceAction] {
        guard device.incomingCapabilities.contains(DataPacket.mprisRequestPacketType) else { 
            return [] 
        }
        guard device.pairingStatus == .Paired else { 
            return [] 
        }
        
        return []
    }
    
    public func performAction(_ id: ServiceAction.Id, forDevice device: Device) {
        // No actions for this service
    }
    
    // MARK: - Packet Handling Methods
    
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
            
            // Get local player
            guard let localPlayer = localMediaController.getLocalPlayer(identity: player) else {
                Log.warning?.message("MPRIS::Request for unknown local player: \(player)")
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
                device.send(transferPacket) { (success, _) in
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
}
