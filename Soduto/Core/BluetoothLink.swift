//
//  BluetoothLink.swift
//  Soduto
//
//  Copyright © 2026 Soduto. All rights reserved.
//

import Foundation
import os

/// A device link over Bluetooth (KDE Connect's RFCOMM backend), created by `BluetoothLinkProvider` once
/// the identity handshake is done.
///
/// Packets are newline-terminated JSON on the multiplexer's default channel. A packet's payload goes on
/// a channel of its own, named in `payloadTransferInfo.uuid`. There is no TLS: the Bluetooth pairing
/// encrypts the link, and the peer's certificate (from its identity packet) is used for pairing and its
/// verification code, as on the network.
///
/// Threading: a reader thread receives packets and hands them to the main thread, where pairing is
/// handled and delegates are told; sends run in order on a serial queue (they block while waiting for
/// the peer's flow-control credit). Delegates are only called on the main thread.
final class BluetoothLink: NSObject, DeviceLink, PairingHandlerDelegate, @unchecked Sendable {

    // MARK: DeviceLink

    let kind: DeviceLinkKind = .bluetooth
    /// Bluetooth carries payloads (slowly); `Device` sends them over the network link when it can
    let transfersPayloadsEfficiently = false

    private(set) var state: DeviceLinkState = .Open
    weak var delegate: DeviceLinkDelegate?
    weak var pairingDelegate: DeviceLinkPairingDelegate?

    let identity: DataPacket?
    let peerCertificate: SecCertificate?
    let peerProtocolVersion: UInt

    var verificationCode: String? { pairingHandler.verificationCode }

    var hasActiveUploadTasks: Bool { activeUploads.withLock { $0 > 0 } }

    // MARK: Private

    private let transport: RFCOMMTransport
    private let multiplexer: BluetoothMultiplexer
    private let config: ConnectionConfiguration
    private let pairingHandler: DefaultPairingHandler
    private let sendQueue = DispatchQueue(label: "com.soduto.bluetooth.send")
    private let downloadQueue = DispatchQueue(label: "com.soduto.bluetooth.download")
    private let activeUploads = OSAllocatedUnfairLock(initialState: 0)
    /// Packets accepted but not sent yet, handed back if the link closes first
    private let queuedPackets = OSAllocatedUnfairLock<[(id: Int64, dataPacket: DataPacket, completionHandler: PacketSendingCompletionHandler?)]>(uncheckedState: [])
    /// Bytes read past the identity packet during the handshake
    private let leftover: Data

    private static let maxPacketSize = 32 * 1024 * 1024

    init(transport: RFCOMMTransport, multiplexer: BluetoothMultiplexer, identity: DataPacket, peerCertificate: SecCertificate, config: ConnectionConfiguration, leftover: Data) throws {
        self.transport = transport
        self.multiplexer = multiplexer
        self.identity = identity
        self.peerCertificate = peerCertificate
        self.config = config
        self.leftover = leftover
        self.peerProtocolVersion = (try? identity.getProtocolVersion()) ?? 7

        let deviceConfig = config.deviceConfig(for: try identity.getDeviceId())
        self.pairingHandler = DefaultPairingHandler(config: deviceConfig)
        super.init()

        pairingHandler.delegate = self
        pairingHandler.setPeerProtocolVersion(peerProtocolVersion)
        pairingHandler.updateVerificationCode()
        pairingHandler.timeoutHandler = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.pairingDelegate?.link(self, pairingFailed: DefaultPairingHandler.Error.timedOut)
                self.pairingDelegate?.link(self, pairingStatusChanged: .Unpaired)
            }
        }
    }

    /// Starts receiving packets; call once the device holds the link
    func startReading() {
        let thread = Thread { [weak self] in
            self?.readLoop()
        }
        thread.name = "Soduto Bluetooth reader"
        thread.start()
    }

    override var description: String {
        let id = (try? identity?.getDeviceId()) ?? ""
        let name = (try? identity?.getDeviceName()) ?? ""
        return "<BluetoothLink:\(transport.device.addressString ?? "?"):\(id):\(name)>"
    }

    // MARK: Receiving

    private func readLoop() {
        guard let channel = multiplexer.defaultChannel else {
            linkClosed()
            return
        }
        var buffer = leftover
        while true {
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer.subdata(in: buffer.startIndex ..< newline)
                buffer.removeSubrange(buffer.startIndex ... newline)
                if !line.isEmpty {
                    handleLine(line)
                }
            }
            guard buffer.count <= Self.maxPacketSize else {
                Logger.network.error("Bluetooth: packet over \(Self.maxPacketSize) bytes from \(self, privacy: .public); closing")
                break
            }
            guard let chunk = multiplexer.read(channel, maxLength: BluetoothMultiplexer.bufferSize) else { break }
            buffer.append(chunk)
        }
        linkClosed()
    }

    private func handleLine(_ line: Data) {
        guard var packet = DataPacket(data: line) else {
            Logger.network.error("Bluetooth: couldn't parse a packet from \(self, privacy: .public)")
            return
        }
        if packet.payloadInfo != nil {
            packet.downloadTask = DownloadTask(packet: packet, multiplexer: multiplexer, writeQueue: downloadQueue, delegateQueue: .main)
        }
        let received = packet
        DispatchQueue.main.async { [weak self] in
            guard let self, self.state == .Open else { return }
            if received.type == DataPacket.pairingPacketType {
                self.handlePairingPacket(received)
            } else if received.isIdentityPacket {
                // Identity was exchanged in the handshake; a later one changes nothing
            } else {
                self.delegate?.link(self, didReadPacket: received)
            }
        }
    }

    /// Mirrors `Connection.handlePairingPacket`, on the main thread
    private func handlePairingPacket(_ packet: DataPacket) {
        do {
            if try packet.getPairFlag() {
                switch pairingHandler.pairingStatus {
                case .Unpaired:
                    let timestamp: Int64? = peerProtocolVersion >= 8 ? try packet.getPairingTimestamp() : nil
                    pairingHandler.setPairingTimestamp(timestamp)
                    pairingHandler.setStatus(.RequestedByPeer)
                    pairingDelegate?.link(self, receivedPairingRequest: PairingRequest(link: self))
                case .Requested:
                    if let deviceId = try? identity?.getDeviceId() {
                        let deviceConfig = config.deviceConfig(for: deviceId)
                        if deviceConfig.certificate == nil {
                            deviceConfig.certificate = peerCertificate
                        }
                    }
                    pairingHandler.setStatus(.Paired)
                    if pairingHandler.pairingStatus == .Paired {
                        pairingDelegate?.link(self, pairingStatusChanged: .Paired)
                    } else {
                        _ = send(DataPacket.unpairPacket())
                    }
                case .Paired:
                    acceptPairing()
                case .RequestedByPeer:
                    break
                }
            } else {
                if pairingHandler.pairingStatus == .Requested {
                    pairingDelegate?.link(self, pairingFailed: DefaultPairingHandler.Error.declinedByPeer)
                }
                pairingHandler.setStatus(.Unpaired)
                pairingDelegate?.link(self, pairingStatusChanged: .Unpaired)
            }
        } catch {
            pairingDelegate?.link(self, pairingFailed: error)
        }
    }

    private func linkClosed() {
        multiplexer.close()
        transport.close()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.state != .Closed else { return }
            self.state = .Closed
            Logger.network.info("Bluetooth link closed: \(self, privacy: .public)")
            self.delegate?.link(self, didSwitchToState: .Closed)
        }
    }

    // MARK: Sending

    func send(_ dataPacket: DataPacket) -> Bool {
        send(dataPacket, whenCompleted: nil)
    }

    func send(_ dataPacket: DataPacket, whenCompleted: PacketSendingCompletionHandler? = nil) -> Bool {
        guard state == .Open else { return false }
        let packetId = dataPacket.id
        queuedPackets.withLockUnchecked { $0.append((packetId, dataPacket, whenCompleted)) }
        sendQueue.async { [weak self] in
            guard let self else { return }
            // Taken back by reclaimUnsentPackets() if the link closed in the meantime
            guard self.queuedPackets.withLockUnchecked({ queue -> Bool in
                guard let index = queue.firstIndex(where: { $0.id == packetId }) else { return false }
                queue.remove(at: index)
                return true
            }) else { return }
            self.transmit(dataPacket, completion: whenCompleted)
        }
        return true
    }

    /// Writes the packet, then its payload if it has one. On the send queue.
    private func transmit(_ original: DataPacket, completion: PacketSendingCompletionHandler?) {
        guard let defaultChannel = multiplexer.defaultChannel else {
            finish(original, completion: completion, packetSent: false, payloadSent: false)
            return
        }
        var packet = original
        var payloadChannel: BluetoothMultiplexer.Channel?
        do {
            if packet.payload != nil {
                let channel = try multiplexer.openChannel()
                payloadChannel = channel
                packet.payloadInfo = ["uuid": channel.id.uuidString as AnyObject]
            }
            try multiplexer.write(defaultChannel, Data(try packet.serialize()))
        } catch {
            Logger.network.error("Bluetooth: couldn't send \(packet.type, privacy: .public): \(error, privacy: .public)")
            if let payloadChannel {
                multiplexer.closeChannel(payloadChannel)
            }
            finish(packet, completion: completion, packetSent: false, payloadSent: false)
            return
        }

        guard let channel = payloadChannel, let stream = packet.payload else {
            finish(packet, completion: completion, packetSent: true, payloadSent: false)
            return
        }

        activeUploads.withLock { $0 += 1 }
        let payloadSent = upload(stream, of: packet, over: channel)
        multiplexer.closeChannel(channel)
        activeUploads.withLock { $0 -= 1 }
        finish(packet, completion: completion, packetSent: true, payloadSent: payloadSent)
    }

    private func upload(_ stream: InputStream, of packet: DataPacket, over channel: BluetoothMultiplexer.Channel) -> Bool {
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: BluetoothMultiplexer.bufferSize)
        var sent: Int64 = 0
        var lastReport = Date.distantPast
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count == 0 { break }
            guard count > 0 else {
                Logger.network.error("Bluetooth: payload stream error for \(packet.type, privacy: .public)")
                return false
            }
            do {
                try multiplexer.write(channel, Data(buffer[0 ..< count]))
            } catch {
                Logger.network.error("Bluetooth: payload upload failed: \(error, privacy: .public)")
                return false
            }
            sent += Int64(count)
            if Date().timeIntervalSince(lastReport) >= 0.5 {
                lastReport = Date()
                let progress = sent
                let total = packet.payloadSize
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.delegate?.link(self, uploadPayloadProgress: progress, totalBytes: total, forPacket: packet)
                }
            }
        }
        return packet.payloadSize.map { sent >= $0 } ?? true
    }

    private func finish(_ packet: DataPacket, completion: PacketSendingCompletionHandler?, packetSent: Bool, payloadSent: Bool) {
        nonisolated(unsafe) let completion = completion
        DispatchQueue.main.async { [weak self] in
            completion?(packetSent, payloadSent)
            if packetSent, let self {
                self.delegate?.link(self, didSendPacket: packet, uploadedPayload: payloadSent)
            }
        }
    }

    func reclaimUnsentPackets() -> [(dataPacket: DataPacket, completionHandler: PacketSendingCompletionHandler?)] {
        queuedPackets.withLockUnchecked { queue in
            defer { queue.removeAll() }
            return queue.map { ($0.dataPacket, $0.completionHandler) }
        }
    }

    func cancelUpload(forPacketId packetId: Int64) {
        // Uploads stream from the send queue in order and can't be interrupted part-way yet
    }

    /// The RFCOMM channel reports a lost peer by closing, so there's nothing to probe
    func sendKeepAlivePacket() {}

    func close() {
        multiplexer.close()
        transport.close()
    }

    func closeAfterWriting() {
        sendQueue.async { [weak self] in
            self?.close()
        }
    }

    // MARK: Pairable

    var pairingStatus: PairingStatus {
        state == .Open ? pairingHandler.pairingStatus : .Unpaired
    }

    func requestPairing() {
        let previous = pairingHandler.pairingStatus
        pairingHandler.requestPairing()
        let current = pairingHandler.pairingStatus
        if current != previous {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pairingDelegate?.link(self, pairingStatusChanged: current)
            }
        }
    }

    func acceptPairing() {
        pairingHandler.acceptPairing()
        if pairingHandler.pairingStatus == .Paired {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pairingDelegate?.link(self, pairingStatusChanged: .Paired)
            }
        }
    }

    func declinePairing() {
        pairingHandler.declinePairing()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pairingDelegate?.link(self, pairingStatusChanged: .Unpaired)
        }
    }

    func unpair() {
        pairingHandler.unpair()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pairingDelegate?.link(self, pairingStatusChanged: .Unpaired)
        }
    }

    func updatePairingStatus(globalStatus: PairingStatus) {
        pairingHandler.updatePairingStatus(globalStatus: globalStatus)
    }
}
