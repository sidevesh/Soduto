//
//  DeviceLink.swift
//  Soduto
//
//  Copyright © 2026 Soduto. All rights reserved.
//

import Foundation
import Security

/// The transport a link runs over. A `Device` keeps at most one link of each kind.
public enum DeviceLinkKind: String, CaseIterable, CustomStringConvertible {
    /// TCP + TLS on the local network (`Connection`)
    case lan
    /// KDE Connect's RFCOMM channel (not implemented yet)
    case bluetooth
    
    public var description: String { rawValue }
}

/// Lifecycle of a link, the same for every transport
public enum DeviceLinkState {
    case Initializing
    case Open
    case Closed
}

/// Called once a packet (and its payload, if any) has been sent, or has failed to send
public typealias PacketSendingCompletionHandler = ((_ packetSent: Bool, _ payloadSent: Bool) -> Void)

/// Events a link reports to its owner (the `Device`).
public protocol DeviceLinkDelegate: AnyObject {
    func link(_ link: DeviceLink, didSwitchToState state: DeviceLinkState)
    func link(_ link: DeviceLink, didSendPacket packet: DataPacket, uploadedPayload: Bool)
    func link(_ link: DeviceLink, didReadPacket packet: DataPacket)
    func linkCapacityChanged(_ link: DeviceLink)
    func link(_ link: DeviceLink, uploadPayloadProgress bytesSent: Int64, totalBytes: Int64?, forPacket packet: DataPacket)
}

public extension DeviceLinkDelegate {
    func link(_ link: DeviceLink, uploadPayloadProgress bytesSent: Int64, totalBytes: Int64?, forPacket packet: DataPacket) {}
}

/// One way of exchanging KDE Connect packets with a device.
///
/// `Connection` (LAN: TCP + TLS) is the only implementation today; a Bluetooth link would be another.
/// `Device` holds its links, pairs through them, and picks one per packet with `link(forSending:)`,
/// so services never deal with transports: they send through the device and receive packets with the
/// link they arrived on.
public protocol DeviceLink: AnyObject, Pairable, CustomStringConvertible {
    var kind: DeviceLinkKind { get }
    var state: DeviceLinkState { get }
    var delegate: DeviceLinkDelegate? { get set }
    
    /// The peer's identity packet, once received
    var identity: DataPacket? { get }
    var peerCertificate: SecCertificate? { get }
    /// Pairing verification code (protocol v8+), shown to the user during pairing
    var verificationCode: String? { get }
    var peerProtocolVersion: UInt { get }
    
    /// Whether this link carries payloads (files, album art, attachments) well. `Device` sends packets
    /// with payloads over such a link when it has one, so a slow link can still carry everything else.
    var transfersPayloadsEfficiently: Bool { get }
    var hasActiveUploadTasks: Bool { get }
    
    /// Queues a packet. Returns false when the link can't take more right now; it reports
    /// `linkCapacityChanged` once it can.
    func send(_ dataPacket: DataPacket, whenCompleted: PacketSendingCompletionHandler?) -> Bool
    /// After the link closed: packets it accepted but never sent, to be sent over another link
    func reclaimUnsentPackets() -> [(dataPacket: DataPacket, completionHandler: PacketSendingCompletionHandler?)]
    func cancelUpload(forPacketId packetId: Int64)
    /// Tests liveness: a write to a dead peer fails and closes the link
    func sendKeepAlivePacket()
    func close()
    /// Closes once everything queued has been written
    func closeAfterWriting()
}
