//
//  CallManager.swift
//  Soduto
//
//  Copyright © 2026 Soduto. All rights reserved.
//

import AppKit
import CoreAudio
import IOBluetooth
import os

/// Takes the phone's calls on this Mac, the way a Mac takes iPhone calls: an incoming-call banner with
/// Accept and Decline, a small in-call window (timer, mute, keypad, audio route, end), and calling out
/// from Messages.
///
/// It works like a car kit: this Mac connects to the phone as a Bluetooth Hands-Free (HFP) device.
/// macOS provides the Bluetooth connection and the call audio (this Mac's microphone and speakers);
/// Soduto shows and manages the call. KDE Connect's own call alerts are suppressed while this is on and
/// connected (TelephonyService asks `isHandlingCalls`), and its caller name fills in the banner.
///
/// Calls answered on the phone stay on the phone: audio is sent back to it and no window appears.
@MainActor
final class CallManager: ObservableObject {

    static let shared = CallManager()

    enum Phase: Equatable {
        case incoming
        case outgoing
        case active
    }

    struct Call: Equatable {
        var number: String?
        var phase: Phase
        var startedAt: Date?
        /// Answered or placed on this Mac (otherwise the phone handles it and Soduto stays out of the way)
        var isHere: Bool
        var isMuted = false
        var audioOnMac = true
    }

    enum ConnectionStatus: Equatable {
        case off
        case noPhone
        case connecting(String)
        case connected(String)
        case disconnected(String)
    }

    @Published private(set) var call: Call?
    @Published private(set) var connectionStatus: ConnectionStatus = .off
    @Published private(set) var callerName: String?
    @Published private(set) var callerPhoto: NSImage?

    /// True while this Mac is connected as the phone's hands-free device
    var isHandlingCalls: Bool {
        if case .connected = connectionStatus { return true }
        return false
    }

    private let engine = HandsFreeEngine()
    private let ringer = Ringer()
    private let microphone = MicrophoneMute()
    private var reconnectTimer: Timer?
    private var defaultsObserver: NSObjectProtocol?
    private var runningAddress: String?

    private init() {
        engine.onEvent = { [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(event) }
            }
        }
    }

    /// Starts or stops according to Settings › Calls; call once at launch
    func activate() {
        update()
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    // MARK: Settings

    /// Paired Bluetooth devices that are phones (for the picker in Settings)
    nonisolated static func pairedPhones() -> [(address: String, name: String)] {
        let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return devices
            .filter { $0.deviceClassMajor == BluetoothDeviceClassMajor(kBluetoothDeviceClassMajorPhone) }
            .compactMap { device in device.addressString.map { ($0, device.name ?? $0) } }
    }

    private func update() {
        let prefs = AppDefaultsStore.Preferences.Calls.self
        guard prefs.isEnabled else {
            stop()
            connectionStatus = .off
            return
        }
        let phones = Self.pairedPhones()
        let address = phones.first(where: { $0.address == prefs.phoneAddress })?.address ?? (phones.count == 1 ? phones[0].address : nil)
        guard let address else {
            stop()
            connectionStatus = .noPhone
            return
        }
        guard address != runningAddress else { return }
        stop()
        runningAddress = address
        let name = phones.first { $0.address == address }?.name ?? address
        connectionStatus = .connecting(name)
        engine.start(address: address)
        // Reconnect while the phone is out of range or busy with another hands-free device
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isHandlingCalls, let address = self.runningAddress else { return }
                self.engine.start(address: address)
            }
        }
    }

    private func stop() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        guard runningAddress != nil else { return }
        runningAddress = nil
        engine.stop()
        endCallUI()
    }

    // MARK: Actions (from the UI)

    func accept() {
        guard var call, call.phase == .incoming else { return }
        call.isHere = true
        self.call = call
        ringer.stop()
        engine.accept()
    }

    func decline() {
        ringer.stop()
        engine.endCall()
    }

    func end() {
        engine.endCall()
    }

    func toggleMute() {
        guard var call else { return }
        call.isMuted.toggle()
        microphone.setMuted(call.isMuted)
        self.call = call
    }

    func toggleAudioRoute() {
        guard var call else { return }
        call.audioOnMac.toggle()
        if call.audioOnMac {
            engine.transferAudioToMac()
        } else {
            engine.transferAudioToPhone()
        }
        self.call = call
    }

    func sendDigit(_ digit: String) {
        engine.sendDTMF(digit)
    }

    /// Calls `number` from the phone, with the audio on this Mac
    func dial(_ number: String) {
        guard isHandlingCalls, call == nil else { return }
        call = Call(number: number, phase: .outgoing, startedAt: nil, isHere: true)
        resolveCaller(number: number)
        CallWindows.shared.showInCall()
        engine.dial(number)
    }

    /// KDE Connect's ringing packet carries the contact's name as the phone knows it
    func noteCaller(name: String?, number: String?) {
        guard call != nil else { return }
        if let name, !name.isEmpty, callerName == nil || callerName == call?.number {
            callerName = name
        }
        if call?.number == nil, let number, !number.isEmpty {
            call?.number = number
            resolveCaller(number: number)
        }
    }

    // MARK: Hands-free events

    private func handle(_ event: HandsFreeEngine.Event) {
        switch event {
        case .connected(let name):
            Logger.services.notice("Calls: connected to \(name, privacy: .public) as a hands-free device")
            connectionStatus = .connected(name)
        case .disconnected(let name):
            Logger.services.notice("Calls: hands-free connection to \(name, privacy: .public) ended")
            connectionStatus = runningAddress == nil ? .off : .disconnected(name)
            endCallUI()
        case .incoming(let number):
            if call == nil {
                call = Call(number: number, phase: .incoming, startedAt: nil, isHere: false)
                callerName = nil
                callerPhoto = nil
                CallWindows.shared.showIncoming()
                if AppDefaultsStore.Preferences.Calls.ringsOnMac {
                    ringer.start()
                }
            } else if call?.number == nil {
                call?.number = number
            }
            if let number { resolveCaller(number: number) }
        case .outgoing(let number):
            if call == nil {
                // Placed on the phone itself: it keeps the call
                call = Call(number: number, phase: .outgoing, startedAt: nil, isHere: false)
                engine.transferAudioToPhone()
            } else if call?.number == nil, let number {
                call?.number = number
                resolveCaller(number: number)
            }
        case .active:
            guard var current = call else { return }
            ringer.stop()
            current.phase = .active
            current.startedAt = current.startedAt ?? Date()
            call = current
            if current.isHere {
                engine.transferAudioToMac()
                CallWindows.shared.hideIncoming()
                CallWindows.shared.showInCall()
            } else {
                // Answered on the phone: keep the audio there, like a Mac when the iPhone picks up
                engine.transferAudioToPhone()
                CallWindows.shared.hideIncoming()
            }
        case .ended:
            endCallUI()
        }
    }

    private func endCallUI() {
        ringer.stop()
        if call?.isMuted == true {
            microphone.setMuted(false)
        }
        call = nil
        callerName = nil
        callerPhoto = nil
        CallWindows.shared.hideIncoming()
        CallWindows.shared.hideInCall()
    }

    /// Name and photo from the phone's synced contacts or this Mac's Contacts
    private func resolveCaller(number: String) {
        let app = AppDelegate.shared()
        guard let contacts = app.serviceManager.service(ofType: ContactsService.self) else { return }
        let phoneName = (runningAddress.flatMap { IOBluetoothDevice(addressString: $0)?.name } ?? "").lowercased()
        let paired = app.deviceManager.pairedDevices
        let device = paired.first { $0.name.lowercased() == phoneName } ?? paired.first { $0.type == .Phone } ?? paired.first
        guard let device, let contact = contacts.lookupContact(phoneNumber: number, deviceId: device.id) else { return }
        callerName = contact.displayName
        callerPhoto = contact.photo
    }
}

// MARK: - Hands-free engine

/// The IOBluetooth hands-free device, on `BluetoothThread`. Reports events through `onEvent` (from that
/// thread) and takes commands from any thread.
final class HandsFreeEngine: NSObject, IOBluetoothHandsFreeDeviceDelegate, @unchecked Sendable {

    enum Event: Sendable {
        case connected(String)
        case disconnected(String)
        case incoming(String?)
        case outgoing(String?)
        case active
        case ended
    }

    var onEvent: (@Sendable (Event) -> Void)?

    // Bluetooth thread only
    private var handsFree: IOBluetoothHandsFreeDevice?
    private var isConnected = false
    private var callSetup = 0
    private var callActive = false
    private var lastNumber: String?

    private var deviceName: String { handsFree?.device?.name ?? "phone" }

    func start(address: String) {
        BluetoothThread.shared.perform { [self] in
            if handsFree != nil && isConnected { return }
            guard let device = IOBluetoothDevice(addressString: address) else {
                Logger.services.error("Calls: no paired Bluetooth device at \(address, privacy: .public)")
                return
            }
            let device_: IOBluetoothHandsFreeDevice? = IOBluetoothHandsFreeDevice(device: device, delegate: self)
            guard let handsFree = device_ else {
                Logger.services.error("Calls: couldn't create a hands-free device for \(device.name ?? address, privacy: .public)")
                return
            }
            self.handsFree = handsFree
            Logger.services.info("Calls: connecting to \(device.name ?? address, privacy: .public) as a hands-free device")
            handsFree.connect()
        }
    }

    func stop() {
        BluetoothThread.shared.perform { [self] in
            handsFree?.disconnect()
            handsFree = nil
            isConnected = false
            callSetup = 0
            callActive = false
        }
    }

    func accept() { onBluetoothThread { $0.acceptCall() } }
    func endCall() { onBluetoothThread { $0.endCall() } }
    func dial(_ number: String) { onBluetoothThread { $0.dialNumber(number) } }
    func sendDTMF(_ digit: String) { onBluetoothThread { $0.sendDTMF(digit) } }
    func transferAudioToMac() { onBluetoothThread { $0.transferAudioToComputer() } }
    func transferAudioToPhone() { onBluetoothThread { $0.transferAudioToPhone() } }

    private func onBluetoothThread(_ action: @escaping @Sendable (IOBluetoothHandsFreeDevice) -> Void) {
        BluetoothThread.shared.perform { [self] in
            guard let handsFree else {
                Logger.services.error("Calls: not connected to the phone")
                return
            }
            action(handsFree)
        }
    }

    /// Combines the phone's "callsetup" and "call" indicators into call events
    private func reportCallState() {
        if callActive {
            onEvent?(.active)
        } else {
            switch callSetup {
            case 1: onEvent?(.incoming(lastNumber))
            case 2, 3: onEvent?(.outgoing(lastNumber))
            default:
                lastNumber = nil
                onEvent?(.ended)
            }
        }
    }

    // MARK: IOBluetoothHandsFreeDelegate

    func handsFree(_ device: IOBluetoothHandsFree!, connected status: NSNumber!) {
        if status?.intValue == Int(kIOReturnSuccess) {
            isConnected = true
            onEvent?(.connected(deviceName))
            // Ask for the current calls, in case one is already ringing or going on
            handsFree?.currentCallList()
        } else {
            Logger.services.error("Calls: hands-free connection failed (\(status?.intValue ?? -1, privacy: .public))")
            onEvent?(.disconnected(deviceName))
        }
    }

    func handsFree(_ device: IOBluetoothHandsFree!, disconnected status: NSNumber!) {
        isConnected = false
        callSetup = 0
        callActive = false
        onEvent?(.disconnected(deviceName))
    }

    func handsFree(_ device: IOBluetoothHandsFree!, scoConnectionOpened status: NSNumber!) {
        Logger.services.info("Calls: call audio connected (\(status?.intValue ?? -1, privacy: .public))")
    }

    func handsFree(_ device: IOBluetoothHandsFree!, scoConnectionClosed status: NSNumber!) {
        Logger.services.info("Calls: call audio disconnected")
    }

    // MARK: IOBluetoothHandsFreeDeviceDelegate

    func handsFree(_ device: IOBluetoothHandsFreeDevice!, isCallActive: NSNumber!) {
        callActive = (isCallActive?.intValue ?? 0) != 0
        reportCallState()
    }

    func handsFree(_ device: IOBluetoothHandsFreeDevice!, callSetupMode: NSNumber!) {
        callSetup = callSetupMode?.intValue ?? 0
        reportCallState()
    }

    func handsFree(_ device: IOBluetoothHandsFreeDevice!, incomingCallFrom number: String!) {
        lastNumber = number
        if callSetup == 1 || !callActive {
            onEvent?(.incoming(number))
        }
    }

    func handsFree(_ device: IOBluetoothHandsFreeDevice!, currentCall: [AnyHashable: Any]!) {
        // The current call list (+CLCC): its number fills in calls placed or answered on the phone
        if let number = currentCall?[IOBluetoothHandsFreeCallNumber] as? String, !number.isEmpty {
            lastNumber = number
            reportCallState()
        }
    }

    func handsFree(_ device: IOBluetoothHandsFreeDevice!, ringAttempt: NSNumber!) {
        if callSetup == 0 && !callActive {
            callSetup = 1
            reportCallState()
        }
    }
}

// MARK: - Ringer

/// Rings on this Mac while a call is incoming (the phone rings too, as with iPhone calls on a Mac)
@MainActor
private final class Ringer {
    private var timer: Timer?
    private let sound = NSSound(named: NSSound.Name("Submarine"))

    func start() {
        guard timer == nil else { return }
        sound?.play()
        timer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.sound?.play() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        sound?.stop()
    }
}

// MARK: - Microphone mute

/// Mutes this Mac's default input (the microphone carrying the call audio) during a call
private final class MicrophoneMute {
    func setMuted(_ muted: Bool) {
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var defaultInput = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defaultInput, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return }
        var mute = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = muted ? 1 : 0
        let status = AudioObjectSetPropertyData(device, &mute, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        if status != noErr {
            Logger.services.error("Calls: couldn't \(muted ? "mute" : "unmute", privacy: .public) the microphone (\(status, privacy: .public))")
        }
    }
}
