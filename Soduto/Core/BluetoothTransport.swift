//
//  BluetoothTransport.swift
//  Soduto
//
//  Copyright © 2026 Soduto. All rights reserved.
//

import Foundation
import IOBluetooth
import os

/// The thread every IOBluetooth call runs on. IOBluetooth delivers its callbacks on the run loop of the
/// thread that started the operation, and blocking writes must not stall the main thread, so all
/// Bluetooth work happens on this one thread with its own run loop.
final class BluetoothThread: Thread, @unchecked Sendable {

    static let shared: BluetoothThread = {
        let thread = BluetoothThread()
        thread.name = "Soduto Bluetooth"
        thread.qualityOfService = .userInitiated
        thread.start()
        thread.ready.wait()
        return thread
    }()

    private let ready = DispatchSemaphore(value: 0)
    private var runLoop: CFRunLoop?

    override func main() {
        runLoop = CFRunLoopGetCurrent()
        // A port keeps the run loop alive while nothing else is scheduled
        RunLoop.current.add(Port(), forMode: .default)
        ready.signal()
        while !isCancelled {
            _ = RunLoop.current.run(mode: .default, before: .distantFuture)
        }
    }

    /// Runs `block` on the Bluetooth thread, soon
    func perform(_ block: @escaping @Sendable () -> Void) {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }

    /// Runs `block` on the Bluetooth thread and waits for it (inline when already on it)
    func performAndWait<T>(_ block: @escaping @Sendable () -> T) -> T {
        if Thread.current === self {
            return block()
        }
        let done = DispatchSemaphore(value: 0)
        let result = OSAllocatedUnfairLock<T?>(uncheckedState: nil)
        perform {
            let value = block()
            result.withLockUnchecked { $0 = value }
            done.signal()
        }
        done.wait()
        return result.withLockUnchecked { $0! }
    }
}

/// An open RFCOMM channel: bytes in through `onData`, bytes out through `write(_:)`.
/// The IOBluetooth objects are only touched on `BluetoothThread`.
final class RFCOMMTransport: NSObject, IOBluetoothRFCOMMChannelDelegate, @unchecked Sendable {

    enum TransportError: Error {
        case notOpen
        case writeFailed(IOReturn)
    }

    let device: IOBluetoothDevice
    private var channel: IOBluetoothRFCOMMChannel?
    private var openCompletion: ((Bool) -> Void)?

    /// Bytes as they arrive, on the Bluetooth thread
    var onData: ((Data) -> Void)?
    /// The channel closed (peer, range, or `close()`), on the Bluetooth thread
    var onClose: (() -> Void)?

    init(device: IOBluetoothDevice) {
        self.device = device
    }

    /// Opens RFCOMM channel `channelID` on the device. Call on the Bluetooth thread; `completion` runs
    /// there too.
    func open(channelID: BluetoothRFCOMMChannelID, completion: @escaping (Bool) -> Void) {
        openCompletion = completion
        var opened: IOBluetoothRFCOMMChannel?
        let result = device.openRFCOMMChannelAsync(&opened, withChannelID: channelID, delegate: self)
        if result == kIOReturnSuccess {
            channel = opened
        } else {
            Logger.network.error("Bluetooth: couldn't open RFCOMM channel \(channelID, privacy: .public) on \(self.device.addressString ?? "?", privacy: .public): \(result, privacy: .public)")
            openCompletion = nil
            completion(false)
        }
    }

    /// Writes all of `data`, split to the channel's MTU. Blocks until written; any thread.
    func write(_ data: Data) throws {
        let result: IOReturn = BluetoothThread.shared.performAndWait { [self] in
            guard let channel, channel.isOpen() else { return kIOReturnNotOpen }
            let mtu = max(Int(channel.getMTU()), 1)
            var offset = 0
            var bytes = [UInt8](data)
            while offset < bytes.count {
                let count = min(mtu, bytes.count - offset)
                let status = bytes.withUnsafeMutableBytes { buffer in
                    channel.writeSync(buffer.baseAddress!.advanced(by: offset), length: UInt16(count))
                }
                guard status == kIOReturnSuccess else { return status }
                offset += count
            }
            return kIOReturnSuccess
        }
        if result == kIOReturnNotOpen {
            throw TransportError.notOpen
        }
        guard result == kIOReturnSuccess else {
            throw TransportError.writeFailed(result)
        }
    }

    func close() {
        BluetoothThread.shared.perform { [self] in
            _ = channel?.close()
        }
    }

    // MARK: IOBluetoothRFCOMMChannelDelegate

    func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        let completion = openCompletion
        openCompletion = nil
        if error != kIOReturnSuccess {
            Logger.network.error("Bluetooth: RFCOMM open failed on \(self.device.addressString ?? "?", privacy: .public): \(error, privacy: .public)")
        }
        completion?(error == kIOReturnSuccess)
    }

    func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        guard let dataPointer, dataLength > 0 else { return }
        onData?(Data(bytes: dataPointer, count: dataLength))
    }

    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        Logger.network.info("Bluetooth: RFCOMM channel to \(self.device.addressString ?? "?", privacy: .public) closed")
        channel = nil
        if let completion = openCompletion {
            openCompletion = nil
            completion(false)
        }
        onClose?()
    }
}
