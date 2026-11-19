//
//  BluetoothMultiplexer.swift
//  Soduto
//
//  Copyright © 2026 Soduto. All rights reserved.
//

import Foundation
import os

/// KDE Connect's Bluetooth multiplexing protocol, version 1 (see "Multiplexing protocol.md" in
/// kdeconnect-kde, and `ConnectionMultiplexer` in kdeconnect-android).
///
/// One Bluetooth connection carries any number of channels, each named by a random UUID. Packets travel
/// on the default channel as newline-terminated JSON; each payload gets a channel of its own. Every
/// message is a 19-byte header (type, big-endian UInt16 length, channel UUID) plus data. A receiver
/// grants credit with READ (up to `bufferSize` bytes outstanding); a sender only WRITEs what it was granted.
///
/// Transport-agnostic: give it a `write` function and feed it the bytes that arrive with `receive(_:)`.
/// Reads and writes on channels block the calling thread until data or credit arrives, so call them
/// from worker threads, never from the thread that delivers incoming bytes.
final class BluetoothMultiplexer: @unchecked Sendable {

    static let defaultChannelId = UUID(uuidString: "a0d0aaf4-1072-4d81-aa35-902a954b1266")!
    /// Most a channel buffers (and so the most credit it grants at once)
    static let bufferSize = 4096
    private static let headerSize = 19
    private static let protocolVersion: UInt16 = 1

    private enum MessageType: UInt8 {
        case protocolVersion = 0
        case openChannel = 1
        case closeChannel = 2
        case read = 3
        case write = 4
    }

    enum MultiplexerError: Error {
        case closed
        case unknownChannel
    }

    /// One logical stream. Its state is guarded by the multiplexer's `state` condition.
    final class Channel: @unchecked Sendable {
        let id: UUID
        fileprivate var buffer = Data()
        /// Credit granted to the peer and not yet used
        fileprivate var requestedReadAmount = 0
        /// Credit the peer granted us and we haven't used yet
        fileprivate var freeWriteAmount = 0
        fileprivate var isOpen = true

        fileprivate init(id: UUID) {
            self.id = id
        }
    }

    /// Called once when the connection ends (either side, or a protocol error)
    var onClose: (@Sendable () -> Void)?

    private let transportWrite: @Sendable (Data) throws -> Void
    /// Keeps each message contiguous on the wire
    private let writeLock = NSLock()
    /// Guards everything below and wakes blocked readers and writers
    private let state = NSCondition()
    private var channels: [UUID: Channel] = [:]
    private var isOpen = true
    private var receivedProtocolVersion = false
    private var incoming = Data()

    init(write: @escaping @Sendable (Data) throws -> Void) {
        self.transportWrite = write
        channels[Self.defaultChannelId] = Channel(id: Self.defaultChannelId)
    }

    /// Sends the protocol version message, which must be the first message on the connection
    func start() {
        var data = Data()
        data.append(contentsOf: Self.bigEndianBytes(Self.protocolVersion))  // lowest supported
        data.append(contentsOf: Self.bigEndianBytes(Self.protocolVersion))  // highest supported
        send(.protocolVersion, channel: Self.defaultChannelId, data: data)
    }

    var defaultChannel: Channel? { channel(Self.defaultChannelId) }

    func channel(_ id: UUID) -> Channel? {
        state.lock()
        defer { state.unlock() }
        return channels[id]
    }

    // MARK: Channels

    /// Opens a channel for an outgoing payload
    func openChannel() throws -> Channel {
        let id = UUID()
        let channel = Channel(id: id)
        state.lock()
        guard isOpen else {
            state.unlock()
            throw MultiplexerError.closed
        }
        channels[id] = channel
        state.unlock()
        send(.openChannel, channel: id, data: Data())
        return channel
    }

    func closeChannel(_ channel: Channel) {
        state.lock()
        let wasOpen = channel.isOpen && channels[channel.id] != nil
        channel.isOpen = false
        channels.removeValue(forKey: channel.id)
        state.broadcast()
        let connectionOpen = isOpen
        state.unlock()
        if wasOpen && connectionOpen {
            send(.closeChannel, channel: channel.id, data: Data())
        }
    }

    /// Up to `maxLength` bytes from the channel, waiting for them if none are buffered. Returns nil once
    /// the channel is closed and drained.
    func read(_ channel: Channel, maxLength: Int) -> Data? {
        state.lock()
        while true {
            if !channel.buffer.isEmpty {
                let count = min(maxLength, channel.buffer.count)
                let chunk = Data(channel.buffer.prefix(count))
                channel.buffer.removeFirst(count)
                state.unlock()
                return chunk
            }
            guard channel.isOpen && isOpen else {
                state.unlock()
                return nil
            }
            let outstanding = channel.buffer.count + channel.requestedReadAmount
            if outstanding < Self.bufferSize {
                let amount = Self.bufferSize - outstanding
                channel.requestedReadAmount += amount
                state.unlock()
                send(.read, channel: channel.id, data: Data(Self.bigEndianBytes(UInt16(amount))))
                state.lock()
                continue
            }
            state.wait()
        }
    }

    /// Writes all of `data`, waiting for the peer's credit as needed
    func write(_ channel: Channel, _ data: Data) throws {
        var offset = 0
        while offset < data.count {
            state.lock()
            while channel.isOpen && isOpen && channel.freeWriteAmount == 0 {
                state.wait()
            }
            guard channel.isOpen && isOpen else {
                state.unlock()
                throw MultiplexerError.closed
            }
            let count = min(channel.freeWriteAmount, data.count - offset, Int(UInt16.max))
            channel.freeWriteAmount -= count
            state.unlock()
            send(.write, channel: channel.id, data: data.subdata(in: offset ..< offset + count))
            offset += count
        }
    }

    /// Ends the connection: every channel reads as closed and blocked callers wake up
    func close() {
        state.lock()
        guard isOpen else {
            state.unlock()
            return
        }
        isOpen = false
        for channel in channels.values {
            channel.isOpen = false
        }
        channels.removeAll()
        state.broadcast()
        state.unlock()
        onClose?()
    }

    // MARK: Incoming

    /// Feeds bytes received from the transport. Never blocks.
    func receive(_ bytes: Data) {
        state.lock()
        incoming.append(bytes)
        var failure: String?
        while failure == nil && incoming.count >= Self.headerSize {
            let base = incoming.startIndex
            let typeByte = incoming[base]
            let length = Int(incoming[base + 1]) << 8 | Int(incoming[base + 2])
            guard incoming.count >= Self.headerSize + length else { break }
            let id = Self.uuid(from: incoming.subdata(in: base + 3 ..< base + Self.headerSize))
            let body = incoming.subdata(in: base + Self.headerSize ..< base + Self.headerSize + length)
            incoming.removeFirst(Self.headerSize + length)

            guard let type = MessageType(rawValue: typeByte) else {
                failure = "unknown message type \(typeByte)"
                break
            }
            if !receivedProtocolVersion && type != .protocolVersion {
                failure = "first message wasn't the protocol version"
                break
            }
            switch type {
            case .protocolVersion:
                guard body.count >= 4 else {
                    failure = "short protocol version message"
                    break
                }
                let minimum = UInt16(body[body.startIndex]) << 8 | UInt16(body[body.startIndex + 1])
                let maximum = UInt16(body[body.startIndex + 2]) << 8 | UInt16(body[body.startIndex + 3])
                if minimum > Self.protocolVersion || maximum < Self.protocolVersion {
                    failure = "unsupported protocol versions \(minimum)–\(maximum)"
                } else {
                    receivedProtocolVersion = true
                }
            case .openChannel:
                if channels[id] == nil {
                    channels[id] = Channel(id: id)
                }
            case .closeChannel:
                if let channel = channels.removeValue(forKey: id) {
                    channel.isOpen = false
                }
            case .read:
                guard body.count == 2 else {
                    failure = "bad READ length"
                    break
                }
                channels[id]?.freeWriteAmount += Int(body[body.startIndex]) << 8 | Int(body[body.startIndex + 1])
            case .write:
                guard let channel = channels[id] else { break }  // unknown channels are ignored
                guard body.count <= channel.requestedReadAmount else {
                    failure = "peer wrote more than it was granted"
                    break
                }
                channel.requestedReadAmount -= body.count
                channel.buffer.append(body)
            }
        }
        state.broadcast()
        state.unlock()

        if let failure {
            Logger.network.error("Bluetooth multiplexer: \(failure, privacy: .public); closing")
            close()
        }
    }

    // MARK: Encoding

    private func send(_ type: MessageType, channel id: UUID, data: Data) {
        var message = Data(capacity: Self.headerSize + data.count)
        message.append(type.rawValue)
        message.append(contentsOf: Self.bigEndianBytes(UInt16(data.count)))
        message.append(contentsOf: Self.bytes(of: id))
        message.append(data)
        writeLock.lock()
        defer { writeLock.unlock() }
        do {
            try transportWrite(message)
        } catch {
            Logger.network.error("Bluetooth multiplexer write failed: \(error, privacy: .public)")
            close()
        }
    }

    private static func bigEndianBytes(_ value: UInt16) -> [UInt8] {
        [UInt8(value >> 8), UInt8(value & 0xFF)]
    }

    /// The UUID's 16 bytes in network order (as Java writes most- then least-significant bits)
    static func bytes(of id: UUID) -> [UInt8] {
        let u = id.uuid
        return [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7, u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15]
    }

    private static func uuid(from data: Data) -> UUID {
        let b = [UInt8](data)
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}
