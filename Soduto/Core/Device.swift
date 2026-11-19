//
//  Device.swift
//  Soduto
//
//  Created by Admin on 2016-08-13.
//  Copyright © 2016 Soduto. All rights reserved.
//

import Foundation
import os

/// Supported device types.
///
/// - Unknown: Device type is not known. Unsupported device types default to this.
/// - Dektop: Device is desktop computer.
/// - Laptop: Device is laptop computer.
/// - Phone: Device is a mobile phone.
/// - Tablet: Device is a tablet.
public enum DeviceType: String, Sendable {
    case Unknown = "unknown"
    case Desktop = "desktop"
    case Laptop = "laptop"
    case Phone = "phone"
    case Tablet = "tablet"
    case TV = "tv"
}

/// Errors thrown by Device instances.
///
/// - InvalidConnection: provided connection has wrong state.
public enum DeviceError: Error {
    case InvalidConnection
}

/// Functionality for handling Device notifications.
public protocol DeviceDelegate: AnyObject {
    func device(_ device: Device, didChangePairingStatus pairingStatus: PairingStatus)
    func device(_ device: Device, didReceivePairingRequest pairingRequest: PairingRequest)
    func device(_ device: Device, pairingFailed error: Error)
    func device(_ device: Device, didChangeReachabilityStatus isReachable: Bool)
    func serviceActions(for device: Device) -> [ServiceAction]
}

/// Functionality for handling incoming data packets from devices.
public protocol DeviceDataPacketHandler: AnyObject {
    /// Handle a packet received from `device` over `link`.
    func handleDataPacket(_ dataPacket: DataPacket, fromDevice device: Device, onLink link: DeviceLink) -> Bool
}


/// Device class represents a remote device. It may be reachable over several links at once, but only
/// one of each kind (LAN, Bluetooth); `link(forSending:)` picks the link for each packet.
public class Device: DeviceLinkDelegate, DeviceLinkPairingDelegate, Pairable, CustomStringConvertible {
    
    // MARK: Types
    
    /// Type for unique device identifier
    public typealias Id = String
    
    private struct PendingDataPacket {
        let packet: DataPacket
        let completionHandler: PacketSendingCompletionHandler?
    }
    
    
    // MARK: Properties
    
    public weak var delegate: DeviceDelegate? = nil
    
    public let id: Id
    public let name: String
    public let type: DeviceType
    public let incomingCapabilities: Set<Service.Capability>
    public let outgoingCapabilities: Set<Service.Capability>
    public let config: DeviceConfiguration
    
    public var peerCertificate: SecCertificate? {
        if let certificate = self.links.first?.peerCertificate { return certificate }
        return self.config.certificate
    }
    public var hostCertificate: SecCertificate? {
        return self.config.hostCertificate?.certificate
    }
    
    /// The pair verification code for protocol v8+ pairing.
    /// This code is displayed to users during pairing so they can verify
    /// both devices show the same code (MITM protection).
    public var verificationCode: String? {
        return self.links.first?.verificationCode
    }
    
    /// The peer's protocol version from the active connection.
    /// Returns nil if no connection is active.
    public var protocolVersion: UInt? {
        return self.links.first?.peerProtocolVersion
    }
    
    public private(set) var isReachable: Bool = false {
        didSet {
            if oldValue != self.isReachable {
                self.delegate?.device(self, didChangeReachabilityStatus: self.isReachable)
            }
        }
    }
    
    private var links: [DeviceLink] = [] // Active links, at most one per kind
    private var lingeringLinks: [DeviceLink] = [] // Replaced links, waiting to finish their uploads
    private var packetHandlers: [DeviceDataPacketHandler] = []
    private var pendingPackets: [PendingDataPacket] = []
    
    
    // MARK: Initialization / Deinitialization
    
    /// Initialize Device with its first link. Device properties are initialized from the link's identity.
    ///
    /// - parameters:
    ///     - link: Fully initialized (i.e. in Open state) link to the device.
    ///     - config: Configuration instance for particular device
    ///
    /// - throws:
    ///     `DeviceError.InvalidConnection` if the link is not `.Open` or has no identity.
    ///     `DataPacket.IdentityError` if the link's identity is invalid.
    public init(link: DeviceLink, config: DeviceConfiguration) throws {
        guard link.state == .Open else { throw DeviceError.InvalidConnection }
        guard let identity = link.identity else { throw DeviceError.InvalidConnection }
        
        self.id = try identity.getDeviceId()
        self.name = try identity.getDeviceName()
        self.type = DeviceType(rawValue: try identity.getDeviceType()) ?? DeviceType.Unknown
        self.incomingCapabilities = try identity.getIncomingCapabilities()
        self.outgoingCapabilities = try identity.getOutgoingCapabilities()
        self.config = config
        self.pairingStatus = self.config.isPaired ? .Paired : .Unpaired
        
        self.addLink(link)
        
        // update config with latest device name and type
        config.name = self.name
        config.type = self.type
    }
    
    /// Initialize Device only with configuration. This is mostly useful to create device instances for
    /// unavailable devices
    ///
    /// - parameters:
    ///     - config: Configuration instance for particular device
    public init(config: DeviceConfiguration) {
        self.id = config.deviceId
        self.name = config.name
        self.type = config.type
        self.incomingCapabilities = Set<Service.Capability>()
        self.outgoingCapabilities = Set<Service.Capability>()
        self.config = config
        self.pairingStatus = self.config.isPaired ? .Paired : .Unpaired
    }
    
    deinit {
        self.discardPendingPackets()
    }
    
    
    // MARK Public API
    
    /// Add a link to the device. A link of the same kind the device already has replaces it; the old
    /// one closes once it has written what it queued.
    ///
    /// - Parameter link: Fully initialized (i.e. in Open state) link to the device.
    public func addLink(_ link: DeviceLink) {
        link.delegate = self
        link.pairingDelegate = self
        self.links.append(link)
        
        // Replace after adding, to avoid a pointless unreachable / reachable flip
        if let index = self.links.firstIndex(where: { $0 !== link && $0.kind == link.kind }) {
            let replaced = self.links.remove(at: index)
            self.lingeringLinks.append(replaced)
            replaced.closeAfterWriting()
        }
        
        self.updatePairingStatus()
        self.updateReachabilityStatus()
    }
    
    /// Register handler for incoming data packets. Most common handler would be Service instances
    public func addDataPacketHandler(_ handler: DeviceDataPacketHandler) {
        self.packetHandlers.append(handler)
    }
    
    /// Register multiple handlers for incoming data packets. Most common handlers would be Service instances
    public func addDataPacketHandlers<S : Sequence>(_ handlers: S) where S.Iterator.Element == DeviceDataPacketHandler {
        for handler in handlers {
            self.addDataPacketHandler(handler)
        }
    }
    
    /// Unregister data packet handler which was registered with such methods as
    /// `addDataPacketHandler(_:)` or `addDataPacketHandlers(_:)`
    public func removeDataPacketHandler(_ handler: DeviceDataPacketHandler) {
        let index = self.packetHandlers.firstIndex { $0 === handler }
        if index != nil {
            self.packetHandlers.remove(at: index!)
        }
    }
    
    /// Return all service actions available to this device
    public func serviceActions() -> [ServiceAction] {
        guard self.pairingStatus == .Paired else { return [] }
        return self.delegate?.serviceActions(for: self) ?? []
    }
    
    /// Send a data packet to remote device over the link `link(forSending:)` picks. Completion block may
    /// be provided - it would be called when packet is successfully sent. On failure completion handler
    /// would not be called - the link would be closed instead.
    public func send(_ packet: DataPacket, whenCompleted: PacketSendingCompletionHandler? = nil) {
        if let link = self.link(forSending: packet) {
            let accepted = link.send(packet, whenCompleted: whenCompleted)
            if !accepted {
                let pendingPacket = PendingDataPacket(packet: packet, completionHandler: whenCompleted)
                self.pendingPackets.insert(pendingPacket, at: 0)
            }
        } else {
            whenCompleted?(false, false)
        }
    }
    
    /// Cancels the upload for a specific packet ID across all active and lingering links.
    /// No-op if the packet ID is not found or the task has already finished.
    public func cancelUpload(forPacketId packetId: Int64) {
        (links + lingeringLinks).forEach { $0.cancelUpload(forPacketId: packetId) }
    }
    
    /// Sends a keepalive on every active link to test liveness.
    /// A write to a dead peer fails (RST or retransmission drop), closing the link through the normal teardown path and making the device available for rediscovery.
    public func probeConnections() {
        for link in self.links {
            link.sendKeepAlivePacket()
        }
    }
    
    /// Cleanup all pending to send packets, executing their completion handlers if any.
    public func discardPendingPackets() {
        for pendingPacket in self.pendingPackets {
            pendingPacket.completionHandler?(false, false)
        }
        self.pendingPackets = []
    }
    
    
    // MARK: DeviceLinkDelegate
    
    public func link(_ link: DeviceLink, didSwitchToState state: DeviceLinkState) {
        Logger.device.debug("link(<\(String(describing: link), privacy: .public)> didSwitchToState:<\(String(describing: state), privacy: .public)>)")
        switch state {
        case .Closed:
            if let index = self.links.firstIndex(where: { $0 === link }) {
                let link = self.links.remove(at: index)
                self.reclaimUnsentPackets(from: link)
                self.updateReachabilityStatus()
            }
            else if let index = self.lingeringLinks.firstIndex(where: { $0 === link }) {
                if link.hasActiveUploadTasks {
                    Logger.device.debug("Device: keeping closed lingering link for active uploads")
                } else {
                    let link = self.lingeringLinks.remove(at: index)
                    self.reclaimUnsentPackets(from: link)
                }
            }
            else {
                assertionFailure("Link not found in device links list")
            }
        default:
            assertionFailure("Unexpected link state switch: \(link) -> \(state)")
        }
    }
    
    /// Forward upload progress events to services that explicitly opt-in by conforming to `DeviceLinkDelegate`.
    public func link(_ link: DeviceLink, uploadPayloadProgress bytesSent: Int64, totalBytes: Int64?, forPacket packet: DataPacket) {
        for handler in packetHandlers {
            if let delegate = handler as? DeviceLinkDelegate {
                delegate.link(link, uploadPayloadProgress: bytesSent, totalBytes: totalBytes, forPacket: packet)
            }
        }
    }
    
    /// Forward upload completion events to services that explicitly opt-in by conforming to `DeviceLinkDelegate`.
    public func link(_ link: DeviceLink, didSendPacket packet: DataPacket, uploadedPayload: Bool) {
        for handler in packetHandlers {
            if let delegate = handler as? DeviceLinkDelegate {
                delegate.link(link, didSendPacket: packet, uploadedPayload: uploadedPayload)
            }
        }
        
        // If this was a lingering link and all uploads are now done, clean it up
        if let index = self.lingeringLinks.firstIndex(where: { $0 === link }), !link.hasActiveUploadTasks {
            Logger.device.debug("Device: lingering link uploads complete, removing")
            self.lingeringLinks.remove(at: index)
        }
    }
    
    public func link(_ link: DeviceLink, didReadPacket packet: DataPacket) {
        self.handle(packet: packet, onLink: link)
    }
    
    public func linkCapacityChanged(_ link: DeviceLink) {
        self.sendPendingPackets()
    }
    
    
    // MARK: DeviceLinkPairingDelegate
    
    public func link(_ link: DeviceLink, receivedPairingRequest request: PairingRequest) {
        Logger.device.debug("Link \(link.description, privacy: .public) received pairing request")
        self.updatePairingStatus()
        self.delegate?.device(self, didReceivePairingRequest: request)
    }
    
    public func link(_ link: DeviceLink, pairingFailed error: Error) {
        Logger.device.debug("Link pairing failed: \(error, privacy: .public)")
        self.delegate?.device(self, pairingFailed: error)
    }
    
    public func link(_ link: DeviceLink, pairingStatusChanged status: PairingStatus) {
        self.updatePairingStatus()
    }
    
    
    // MARK: Pairable
    
    /// Not used - present only to comply Pairable protocol
    public var pairingDelegate: DeviceLinkPairingDelegate? = nil
    
    public var pairingStatus: PairingStatus {
        didSet {
            if pairingStatus != oldValue {
                self.delegate?.device(self, didChangePairingStatus: self.pairingStatus)
            }
        }
    }
    
    public func requestPairing() {
        if let link = self.linkForPairing() {
            if link.pairingStatus == .RequestedByPeer {
                link.acceptPairing()
            } else {
                link.requestPairing()
            }
        }
    }
    
    public func acceptPairing() {
        guard let link = self.linkForPairing() else {
            Logger.device.error("acceptPairing: no link found for pairing")
            return
        }
        guard link.pairingStatus == .RequestedByPeer else {
            Logger.device.error("acceptPairing: link status is \(String(describing: link.pairingStatus), privacy: .public), expected RequestedByPeer")
            return
        }
        Logger.device.debug("acceptPairing: accepting pairing on link")
        link.acceptPairing()
    }
    
    public func declinePairing() {
        for link in self.links {
            switch link.pairingStatus {
            case .RequestedByPeer:
                link.declinePairing()
                break
            case .Paired, .Requested:
                link.unpair()
                break
            default:
                break
            }
        }
    }
    
    public func unpair() {
        for link in self.links {
            switch link.pairingStatus {
            case .Paired, .Requested:
                link.unpair()
                break
            case .RequestedByPeer:
                link.declinePairing()
                break
            default:
                break
            }
        }
        
        // Device might be unavailable and no connections present - update status once more to be sure
        self.updatePairingStatus(globalStatus: .Unpaired)
    }
    
    /// Close every link (force reconnect)
    public func closeAllConnections() {
        // Iterate a copy: closing a link removes it from self.links
        for link in self.links {
            link.close()
        }
    }
    
    public func updatePairingStatus(globalStatus: PairingStatus) {
        for link in self.links {
            link.updatePairingStatus(globalStatus: globalStatus)
        }
        self.config.isPaired = globalStatus == .Paired
        if !self.config.isPaired {
            self.config.certificate = nil
        }
        self.pairingStatus = globalStatus
    }
    
    
    // MARK: CustomStringConvertible
    
    public var description: String {
        return "<Device:\(self.id):\(self.name)>"
    }
    
    
    // MARK: Private
    
    private func updateReachabilityStatus() {
        self.isReachable = !self.links.isEmpty
    }
    
    private func updatePairingStatus() {
        var status: PairingStatus = .Unpaired
        
        if !self.links.isEmpty {
            for link in self.links {
                if link.pairingStatus == .Paired {
                    status = .Paired
                    break
                }
                if (link.pairingStatus == .Requested || link.pairingStatus == .RequestedByPeer) && status == .Unpaired {
                    status = link.pairingStatus
                }
            }
        } else {
            status = self.config.isPaired ? .Paired : .Unpaired
        }
        
        self.updatePairingStatus(globalStatus: status)
    }
    
    /// Choose a link most appropriate for pairing. Return `nil` if pairing seems inappropriate.
    private func linkForPairing() -> DeviceLink? {
        var best: DeviceLink? = nil
        
        for link in self.links {
            switch link.pairingStatus {
            case .Unpaired:
                if best == nil {
                    best = link
                }
            case .RequestedByPeer:
                return link
            case .Requested, .Paired:
                return nil
            }
        }
        
        return best
    }
    
    /// Preference order for packets without a payload. Packets with a payload go to the first paired
    /// link that `transfersPayloadsEfficiently` (falling back to any paired link), so file transfers
    /// can use the network link while a slower link carries everything else.
    private static let linkPreference: [DeviceLinkKind] = [.lan, .bluetooth]
    
    /// Choose the link to send `packet` over: only paired links qualify.
    private func link(forSending packet: DataPacket) -> DeviceLink? {
        let paired = self.links
            .filter { $0.pairingStatus == .Paired }
            .sorted { (Self.linkPreference.firstIndex(of: $0.kind) ?? .max) < (Self.linkPreference.firstIndex(of: $1.kind) ?? .max) }
        if packet.hasPayload(), let fast = paired.first(where: { $0.transfersPayloadsEfficiently }) {
            return fast
        }
        return paired.first
    }
    
    /// Pass received data packet to the handlers, registered with methods such as
    /// `addDataPacketHandler(_:)` or `addDataPacketHandlers(_:)`
    private func handle(packet: DataPacket, onLink link: DeviceLink) {
        for handler in self.packetHandlers {
            if handler.handleDataPacket(packet, fromDevice: self, onLink: link) {
                return
            }
        }
    }
    
    /// Try sending packets from pendingPackets list, send as many as possible until no link accepts any.
    private func sendPendingPackets() {
        while let pendingPacket = self.pendingPackets.popLast() {
            guard let link = self.link(forSending: pendingPacket.packet) else {
                self.pendingPackets.append(pendingPacket)
                break
            }
            if !link.send(pendingPacket.packet, whenCompleted: pendingPacket.completionHandler) {
                self.pendingPackets.append(pendingPacket)
                break
            }
        }
    }
    
    /// Take unsent packets from a closed link, put them into pendingPackets list and try resend them if possible.
    private func reclaimUnsentPackets(from link: DeviceLink) {
        assert(link.state == .Closed, "Link needs to be closed in order to reclaim its packets: \(link)")
        
        for unsentPacket in link.reclaimUnsentPackets() {
            self.pendingPackets.append(PendingDataPacket(packet: unsentPacket.dataPacket, completionHandler: unsentPacket.completionHandler))
        }
        
        self.sendPendingPackets()
    }
}
