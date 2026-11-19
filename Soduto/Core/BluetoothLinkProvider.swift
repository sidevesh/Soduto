//
//  BluetoothLinkProvider.swift
//  Soduto
//
//  Copyright © 2026 Soduto. All rights reserved.
//

import Foundation
import IOBluetooth
import os

public protocol BluetoothLinkProviderDelegate: AnyObject {
    /// A Bluetooth link finished its handshake (main thread)
    func bluetoothLinkProvider(_ provider: BluetoothLinkProvider, didCreateLink link: DeviceLink)
}

/// Connects to phones over Bluetooth with KDE Connect's RFCOMM service.
///
/// The phone must be paired with this Mac in System Settings › Bluetooth, and Bluetooth must be turned on
/// in KDE Connect on the phone (it then listens on the KDE Connect service). This Mac connects as the
/// client: every so often it looks for paired phones offering the service and connects to those it isn't
/// connected to. On a new connection the phone sends its identity first (with its certificate), this
/// Mac checks it and replies with its own, then both use the link.
///
/// Not implemented yet: this Mac publishing the service so the phone can connect to it.
///
/// Threading: all IOBluetooth work and the provider's state live on `BluetoothThread`; handshakes run on
/// worker threads (their reads block); the delegate is told on the main thread.
public final class BluetoothLinkProvider: NSObject, IOBluetoothDeviceAsyncCallbacks, @unchecked Sendable {

    /// KDE Connect's RFCOMM service
    static let serviceUUID = UUID(uuidString: "185f3df4-3268-4e3f-9fca-d4d5059915bd")!
    private static let scanInterval: TimeInterval = 30
    /// How often to ask a phone for its services over the air (cached records are checked every scan)
    private static let serviceQueryInterval: TimeInterval = 120
    private static let handshakeTimeout: TimeInterval = 15

    public weak var delegate: BluetoothLinkProviderDelegate?

    private let config: ConnectionConfiguration

    // Bluetooth thread only
    private var scanTimer: Timer?
    /// Addresses with a connection in progress or established
    private var activeAddresses: Set<String> = []
    private var transports: [String: RFCOMMTransport] = [:]
    private var lastServiceQuery: [String: Date] = [:]

    private lazy var serviceSDPUUID: IOBluetoothSDPUUID = {
        let bytes = BluetoothMultiplexer.bytes(of: Self.serviceUUID)
        return bytes.withUnsafeBytes { IOBluetoothSDPUUID(bytes: $0.baseAddress, length: $0.count) }
    }()

    public init(config: ConnectionConfiguration) {
        self.config = config
        super.init()
    }

    // MARK: Start / stop

    public func start() {
        BluetoothThread.shared.perform { [self] in
            guard scanTimer == nil else { return }
            Logger.network.info("Bluetooth: looking for phones with KDE Connect every \(Int(Self.scanInterval)) s")
            let timer = Timer(timeInterval: Self.scanInterval, repeats: true) { [weak self] _ in
                self?.scan()
            }
            RunLoop.current.add(timer, forMode: .default)
            scanTimer = timer
            scan()
        }
    }

    public func stop() {
        BluetoothThread.shared.perform { [self] in
            scanTimer?.invalidate()
            scanTimer = nil
            for transport in transports.values {
                transport.close()
            }
        }
    }

    /// Look again now (after waking, for example)
    public func restart() {
        BluetoothThread.shared.perform { [self] in
            if scanTimer != nil {
                scan()
            }
        }
    }

    // MARK: Discovery (Bluetooth thread)

    private func scan() {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        for device in paired {
            guard let address = device.addressString, !activeAddresses.contains(address) else { continue }
            if let channelID = rfcommChannel(of: device) {
                connect(device, channelID: channelID)
            } else if isPhone(device), Date().timeIntervalSince(lastServiceQuery[address] ?? .distantPast) >= Self.serviceQueryInterval {
                // The cached service list predates KDE Connect's Bluetooth setting; ask the phone again
                lastServiceQuery[address] = Date()
                _ = device.performSDPQuery(self, uuids: [serviceSDPUUID])
            }
        }
    }

    private func isPhone(_ device: IOBluetoothDevice) -> Bool {
        device.deviceClassMajor == BluetoothDeviceClassMajor(kBluetoothDeviceClassMajorPhone)
    }

    /// The RFCOMM channel of the KDE Connect service, from the device's cached service records
    private func rfcommChannel(of device: IOBluetoothDevice) -> BluetoothRFCOMMChannelID? {
        guard let record = device.getServiceRecord(for: serviceSDPUUID) else { return nil }
        var channelID: BluetoothRFCOMMChannelID = 0
        guard record.getRFCOMMChannelID(&channelID) == kIOReturnSuccess else { return nil }
        return channelID
    }

    public func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        guard let device, status == kIOReturnSuccess, let address = device.addressString,
              !activeAddresses.contains(address), let channelID = rfcommChannel(of: device) else { return }
        connect(device, channelID: channelID)
    }

    public func remoteNameRequestComplete(_ device: IOBluetoothDevice!, status: IOReturn) {}
    public func connectionComplete(_ device: IOBluetoothDevice!, status: IOReturn) {}

    // MARK: Connecting (Bluetooth thread)

    private func connect(_ device: IOBluetoothDevice, channelID: BluetoothRFCOMMChannelID) {
        guard let address = device.addressString else { return }
        activeAddresses.insert(address)
        Logger.network.info("Bluetooth: connecting to \(device.name ?? address, privacy: .public) (RFCOMM channel \(channelID, privacy: .public))")

        let transport = RFCOMMTransport(device: device)
        let multiplexer = BluetoothMultiplexer { [weak transport] data in
            guard let transport else { throw RFCOMMTransport.TransportError.notOpen }
            try transport.write(data)
        }
        transport.onData = { data in multiplexer.receive(data) }
        transport.onClose = { [weak self] in
            multiplexer.close()
            self?.transports.removeValue(forKey: address)
            self?.activeAddresses.remove(address)
        }
        transports[address] = transport

        transport.open(channelID: channelID) { [weak self] opened in
            guard let self else { return }
            guard opened else {
                self.transports.removeValue(forKey: address)
                self.activeAddresses.remove(address)
                return
            }
            multiplexer.start()
            let thread = Thread { [weak self] in
                self?.handshake(transport: transport, multiplexer: multiplexer)
            }
            thread.name = "Soduto Bluetooth handshake"
            thread.start()
        }
    }

    // MARK: Handshake (worker thread)

    /// As the client: read the phone's identity, check it, send ours, then hand the link over
    private func handshake(transport: RFCOMMTransport, multiplexer: BluetoothMultiplexer) {
        let deadline = DispatchWorkItem { [weak multiplexer] in
            Logger.network.error("Bluetooth: no identity from \(transport.device.name ?? "?", privacy: .public) in time")
            multiplexer?.close()
            transport.close()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.handshakeTimeout, execute: deadline)
        defer { deadline.cancel() }

        guard let channel = multiplexer.defaultChannel else { return }
        var buffer = Data()
        var newline: Data.Index?
        while newline == nil {
            guard let chunk = multiplexer.read(channel, maxLength: BluetoothMultiplexer.bufferSize) else {
                transport.close()
                return
            }
            buffer.append(chunk)
            newline = buffer.firstIndex(of: UInt8(ascii: "\n"))
        }
        let line = buffer.subdata(in: buffer.startIndex ..< newline!)
        let leftover = buffer.subdata(in: buffer.index(after: newline!) ..< buffer.endIndex)

        do {
            guard let identity = DataPacket(data: line) else { throw HandshakeError.invalidIdentity }
            try identity.validateIdentityType()
            let deviceId = try identity.getDeviceId()
            guard deviceId != config.hostDeviceId else { throw HandshakeError.connectedToSelf }
            guard let pem = identity.body["certificate"] as? String,
                  let certificate = Self.certificate(fromPEM: pem) else { throw HandshakeError.missingCertificate }

            // The certificate must belong to that device id, and to the device as paired
            var commonName: CFString?
            SecCertificateCopyCommonName(certificate, &commonName)
            guard (commonName as String?) == deviceId else { throw HandshakeError.certificateMismatch }
            let deviceConfig = config.deviceConfig(for: deviceId)
            if deviceConfig.isPaired, let stored = deviceConfig.certificate,
               !CertificateUtils.compareCertificates(stored, certificate) {
                throw HandshakeError.certificateMismatch
            }

            guard let ownPEM = hostCertificatePEM() else { throw HandshakeError.missingCertificate }
            let ownIdentity = DataPacket.identityPacket(additionalProperties: ["certificate": ownPEM as AnyObject], config: config)
            try multiplexer.write(channel, Data(try ownIdentity.serialize()))

            let link = try BluetoothLink(transport: transport, multiplexer: multiplexer, identity: identity,
                                         peerCertificate: certificate, config: config, leftover: leftover)
            Logger.network.info("Bluetooth: connected to \(link, privacy: .public)")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.bluetoothLinkProvider(self, didCreateLink: link)
                link.startReading()
            }
        } catch {
            Logger.network.error("Bluetooth: handshake with \(transport.device.name ?? "?", privacy: .public) failed: \(String(describing: error), privacy: .public)")
            multiplexer.close()
            transport.close()
        }
    }

    private enum HandshakeError: Error {
        case invalidIdentity
        case connectedToSelf
        case missingCertificate
        case certificateMismatch
    }

    // MARK: Certificates

    private func hostCertificatePEM() -> String? {
        guard let identity = config.hostCertificate else { return nil }
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else { return nil }
        let base64 = (SecCertificateCopyData(certificate) as Data).base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN CERTIFICATE-----\n\(base64)\n-----END CERTIFICATE-----\n"
    }

    private static func certificate(fromPEM pem: String) -> SecCertificate? {
        let base64 = pem
            .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        guard let der = Data(base64Encoded: base64) else { return nil }
        return SecCertificateCreateWithData(nil, der as CFData)
    }
}
