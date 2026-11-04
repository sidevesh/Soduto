//
//  RunCommandService.swift
//  Soduto
//
//  Created by Swapnil Devesh on 2025-04-19.
//  Copyright © 2025 Soduto. All rights reserved.
//

import Foundation
import Cocoa
import os

/// Run commands on remote devices or let remote devices run commands on this device.
///
/// Incoming side (remote device runs commands defined on this Mac) follows the KDE Connect desktop plugin:
/// - `kdeconnect.runcommand` carries the command list and `canAddCommand: true`
/// - `kdeconnect.runcommand.request` with `key` runs a command, `requestCommandList` re-sends the list,
///   `setup` opens the command editor on this Mac, and `stop` terminates running commands
/// - `kdeconnect.runcommand.output` streams `commandStarted` / `commandOutput` (stdout/stderr lines) /
///   `commandFinished` back to peers that declare it as an incoming capability (KDE Connect Android does)
public class RunCommandService: BidirectionalService, RunCommandsWindowControllerDelegate {
    
    // MARK: Types
    
    enum ActionId: ServiceAction.Id {
        case runCommand = 1
    }
    
    public struct Command: Codable {
        static let defaultShell = "/bin/zsh"
        
        let uuid: String
        var name: String
        var command: String
        var shell: String
        var isEnabled: Bool
        
        init(uuid: String, name: String, command: String, shell: String = Command.defaultShell, isEnabled: Bool = true) {
            self.uuid = uuid
            self.name = name
            self.command = command
            self.shell = shell
            self.isEnabled = isEnabled
        }
        
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.uuid = try container.decode(String.self, forKey: .uuid)
            self.name = try container.decode(String.self, forKey: .name)
            self.command = try container.decode(String.self, forKey: .command)
            self.shell = try container.decodeIfPresent(String.self, forKey: .shell) ?? Command.defaultShell
            self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        }
    }
    
    
    // MARK: Properties
    
    public static let serviceId: Service.Id = "com.soduto.services.runcommand"
    
    public var incomingCapabilities: Set<Service.Capability> {
        var caps = Set<Service.Capability>()
        if incomingEnabled { caps.insert(DataPacket.runCommandRequestPacketType) }
        if outgoingEnabled { caps.insert(DataPacket.runCommandPacketType) }
        return caps
    }
    public var outgoingCapabilities: Set<Service.Capability> {
        var caps = Set<Service.Capability>()
        if incomingEnabled {
            caps.insert(DataPacket.runCommandPacketType)
            caps.insert(DataPacket.runCommandOutputPacketType)
        }
        if outgoingEnabled { caps.insert(DataPacket.runCommandRequestPacketType) }
        return caps
    }
    
    var userDefaults: UserDefaults = .standard
    let incomingPreferenceKey = AppDefaultsStore.Preferences.Services.RunCommand.incomingKey
    let outgoingPreferenceKey = AppDefaultsStore.Preferences.Services.RunCommand.outgoingKey
    
    public var localCommands: [Command] {
        get {
            guard let data = userDefaults.data(forKey: AppDefaultsStore.Preferences.Services.RunCommand.commandsKey) else { return [] }
            return (try? JSONDecoder().decode([Command].self, from: data)) ?? []
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            userDefaults.set(data, forKey: AppDefaultsStore.Preferences.Services.RunCommand.commandsKey)
            guard incomingEnabled else { return }
            for device in devices where device.incomingCapabilities.contains(DataPacket.runCommandPacketType) {
                sendCommandList(to: device)
            }
        }
    }
    
    private var devices: [Device] = []
    private var remoteCommands: [Device.Id: [String: [String: String]]] = [:]
    
    /// Processes started on behalf of remote devices, keyed by the `id` reported in `kdeconnect.runcommand.output`.
    /// Main-thread confined.
    private var runningProcesses: [Int: Process] = [:]
    private var nextProcessId: Int = 0
    
    /// Command editor opened when a remote device sends a `setup` request.
    private var commandsWindowController: RunCommandsWindowController?
    
    
    // MARK: Service
    
    public func handleDataPacket(_ dataPacket: DataPacket, fromDevice device: Device, onConnection connection: Connection) -> Bool {
        do {
            switch dataPacket.type {
            case DataPacket.runCommandPacketType:
                guard outgoingEnabled else { return true }
                if let commandList = try dataPacket.getCommandList() {
                    self.remoteCommands[device.id] = commandList
                    Logger.services.debug("Received command list from \(device.name, privacy: .public)")
                }
            case DataPacket.runCommandRequestPacketType:
                guard incomingEnabled else { return true }
                if let key = try dataPacket.getRequestKey() {
                    executeLocalCommand(key, device: device)
                } else if try dataPacket.isRequestingCommandList() {
                    sendCommandList(to: device)
                } else if dataPacket.isSetupRequest {
                    showCommandEditor()
                } else if dataPacket.isStopRequest {
                    stopRunningCommands()
                }
            default:
                return false
            }
        } catch {
            Logger.services.error("Error handling run command packet: \(error, privacy: .public)")
        }
        return true
    }
    
    public func setup(for device: Device) {
        guard !self.devices.contains(where: { $0.id == device.id }) else { return }
        
        self.devices.append(device)
        
        if device.incomingCapabilities.contains(DataPacket.runCommandRequestPacketType) {
            send(DataPacket.runCommandListRequestPacket(), to: device)
        }
        
        if incomingEnabled, device.incomingCapabilities.contains(DataPacket.runCommandPacketType) {
            sendCommandList(to: device)
        }
    }
    
    public func cleanup(for device: Device) {
        if let index = self.devices.firstIndex(where: { $0.id == device.id }) {
            self.devices.remove(at: index)
        }
        self.remoteCommands.removeValue(forKey: device.id)
    }
    
    public func actions(for device: Device) -> [ServiceAction] {
        guard outgoingEnabled else { return [] }
        guard device.incomingCapabilities.contains(DataPacket.runCommandRequestPacketType) else { return [] }
        guard let deviceCommands = remoteCommands[device.id], !deviceCommands.isEmpty else { return [] }
        
        let commandActions: [ServiceAction] = deviceCommands.compactMap { uuid, commandInfo in
            guard let name = commandInfo["name"] else { return nil }
            return ServiceAction(
                id: ActionId.runCommand.rawValue,
                title: name,
                description: "Run command on remote device",
                service: self,
                device: device,
                userInfo: ["uuid": uuid]
            )
        }
        
        return [ServiceAction(
            id: ActionId.runCommand.rawValue,
            title: "Run Command",
            description: "Run a command on the remote device",
            service: self,
            device: device,
            children: commandActions
        )]
    }
    
    public func performAction(_ id: ServiceAction.Id, forDevice device: Device, userInfo: [String: Any]?) {
        guard let actionId = ActionId(rawValue: id) else { return }
        
        switch actionId {
        case .runCommand:
            guard let userInfo = userInfo, let uuid = userInfo["uuid"] as? String else { return }
            send(DataPacket.runCommandRequestPacket(key: uuid), to: device)
        }
    }
    
    
    // MARK: RunCommandsWindowControllerDelegate
    
    func getLocalCommands() -> [Command]? {
        return localCommands
    }
    
    func saveLocalCommands(_ commands: [Command]) {
        localCommands = commands
    }
    
    
    // MARK: Private methods
    
    /// Opens the local command editor, answering a remote `setup` request (the "add command" button on the phone).
    private func showCommandEditor() {
        if commandsWindowController == nil {
            let controller = RunCommandsWindowController()
            controller.delegate = self
            commandsWindowController = controller
        }
        commandsWindowController?.showWindow(nil)
    }
    
    /// Terminates every command started on behalf of a remote device, answering a remote `stop` request.
    /// Each process still reports `commandFinished` through its termination handler.
    private func stopRunningCommands() {
        guard !runningProcesses.isEmpty else { return }
        Logger.services.info("Stopping \(self.runningProcesses.count, privacy: .public) running command(s) on remote request")
        for process in runningProcesses.values where process.isRunning {
            process.terminate()
        }
    }
    
    private func executeLocalCommand(_ key: String, device: Device) {
        guard let commandData = localCommands.first(where: { $0.uuid == key }) else {
            Logger.services.error("Command with key \(key, privacy: .public) not found")
            return
        }
        guard commandData.isEnabled else {
            Logger.services.notice("Refusing to execute disabled command: \(commandData.name, privacy: .public)")
            return
        }
        
        Logger.services.debug("Executing command: \(commandData.name, privacy: .public)")
        
        let processId = nextProcessId
        nextProcessId = nextProcessId == Int(Int32.max) ? 0 : nextProcessId + 1
        let reportsOutput = device.incomingCapabilities.contains(DataPacket.runCommandOutputPacketType)
        
        let task = Process()
        task.executableURL = URL(fileURLWithPath: commandData.shell)
        task.arguments = ["-l", "-c", commandData.command]
        
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        task.standardOutput = stdoutPipe
        task.standardError = stderrPipe
        
        // Drain the pipes asynchronously. Without an active reader, the process would block forever
        // once the pipe buffer fills (~64KB) on verbose commands like `brew update`.
        // readabilityHandler fires on a private background queue; complete lines are streamed to the
        // remote device as `commandOutput` packets.
        let stdoutLines = LineSplitter()
        let stderrLines = LineSplitter()
        let commandName = commandData.name
        
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let lines = stdoutLines.append(chunk)
            guard reportsOutput, !lines.isEmpty else { return }
            DispatchQueue.main.async { self?.sendOutput(id: processId, stdout: lines, stderr: [], to: device) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let lines = stderrLines.append(chunk)
            guard reportsOutput, !lines.isEmpty else { return }
            DispatchQueue.main.async { self?.sendOutput(id: processId, stdout: [], stderr: lines, to: device) }
        }
        
        // Runs on a background thread once the process exits. The readability handlers keep draining
        // until EOF on their own; give them a moment to deliver the tail of the output, then flush any
        // unterminated last line and report completion on the main thread. (Reading the pipes to EOF
        // here instead would hang if the command left a background child holding them open.)
        task.terminationHandler = { [weak self] process in
            let exitCode = process.terminationStatus
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                guard let self else { return }
                let remainingStdout = stdoutLines.flush()
                let remainingStderr = stderrLines.flush()
                self.runningProcesses.removeValue(forKey: processId)
                if exitCode == 0 {
                    Logger.services.info("Command '\(commandName, privacy: .public)' completed (exit 0)")
                } else {
                    Logger.services.error("Command '\(commandName, privacy: .public)' failed (exit \(exitCode, privacy: .public))")
                }
                guard reportsOutput else { return }
                if !remainingStdout.isEmpty || !remainingStderr.isEmpty {
                    self.sendOutput(id: processId, stdout: remainingStdout, stderr: remainingStderr, to: device)
                }
                self.sendOutputPacket(DataPacket.runCommandFinishedPacket(id: processId, exitCode: Int(exitCode)), to: device)
            }
        }
        
        do {
            try task.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            Logger.services.error("Error launching command '\(commandData.name, privacy: .public)': \(error, privacy: .public)")
            if reportsOutput {
                sendOutputPacket(DataPacket.runCommandStartedPacket(id: processId, command: commandData.command), to: device)
                sendOutput(id: processId, stdout: [], stderr: [error.localizedDescription], to: device)
                sendOutputPacket(DataPacket.runCommandFinishedPacket(id: processId, exitCode: 1), to: device)
            }
            return
        }
        
        runningProcesses[processId] = task
        if reportsOutput {
            sendOutputPacket(DataPacket.runCommandStartedPacket(id: processId, command: commandData.command), to: device)
        }
    }
    
    /// Sends output lines in batches of at most 5 per stream, matching the KDE Connect desktop plugin.
    private func sendOutput(id: Int, stdout: [String], stderr: [String], to device: Device) {
        for start in stride(from: 0, to: stdout.count, by: 5) {
            let batch = Array(stdout[start..<min(start + 5, stdout.count)])
            Logger.services.debug("stdout: \(batch.joined(separator: "\n"), privacy: .public)")
            sendOutputPacket(DataPacket.runCommandOutputPacket(id: id, stdout: batch, stderr: []), to: device)
        }
        for start in stride(from: 0, to: stderr.count, by: 5) {
            let batch = Array(stderr[start..<min(start + 5, stderr.count)])
            Logger.services.debug("stderr: \(batch.joined(separator: "\n"), privacy: .public)")
            sendOutputPacket(DataPacket.runCommandOutputPacket(id: id, stdout: [], stderr: batch), to: device)
        }
    }
    
    /// Output packets belong to the incoming direction (we are answering the remote's run request).
    private func sendOutputPacket(_ packet: DataPacket, to device: Device) {
        guard incomingEnabled else { return }
        device.send(packet)
    }
    
    private func sendCommandList(to device: Device) {
        device.send(DataPacket.runCommandListPacket(commandList: localCommandsToDict()))
    }
    
    private func localCommandsToDict() -> [String: [String: String]] {
        var result: [String: [String: String]] = [:]
        for command in localCommands where command.isEnabled {
            result[command.uuid] = ["name": command.name, "command": command.command]
        }
        return result
    }
}


// MARK: - LineSplitter

/// Accumulates process output chunks and hands back complete lines. Thread-safe.
private final class LineSplitter {
    private var pending = Data()
    private let lock = NSLock()
    private static let newline = Data([0x0A])
    
    /// Appends a chunk and returns the lines it completes (without the trailing newline).
    func append(_ chunk: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        pending.append(chunk)
        var lines: [String] = []
        while let range = pending.range(of: LineSplitter.newline) {
            lines.append(LineSplitter.decode(pending.subdata(in: pending.startIndex..<range.lowerBound)))
            pending.removeSubrange(pending.startIndex..<range.upperBound)
        }
        return lines
    }
    
    /// Returns the final unterminated line, if any.
    func flush() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard !pending.isEmpty else { return [] }
        let line = LineSplitter.decode(pending)
        pending.removeAll()
        return [line]
    }
    
    private static func decode(_ data: Data) -> String {
        var line = String(decoding: data, as: UTF8.self)
        if line.hasSuffix("\r") { line.removeLast() }
        return line
    }
}


// MARK: - DataPacket (Run Command)

fileprivate extension DataPacket {
    
    // MARK: Types
    
    enum RunCommandError: Error {
        case wrongType
        case invalidCommandList
        case invalidKey
        case invalidRequestFlag
    }
    
    struct RunCommandProperty {
        static let key = "key"
        static let commandList = "commandList"
        static let requestCommandList = "requestCommandList"
        static let canAddCommand = "canAddCommand"
        static let setup = "setup"
        static let stop = "stop"
        static let id = "id"
        static let command = "command"
        static let commandStarted = "commandStarted"
        static let commandOutput = "commandOutput"
        static let commandFinished = "commandFinished"
        static let stdout = "stdout"
        static let stderr = "stderr"
        static let success = "success"
        static let exitCode = "exitCode"
    }
    
    
    // MARK: Properties
    
    static let runCommandPacketType = "kdeconnect.runcommand"
    static let runCommandRequestPacketType = "kdeconnect.runcommand.request"
    static let runCommandOutputPacketType = "kdeconnect.runcommand.output"
    
    var isRunCommandPacket: Bool { return self.type == DataPacket.runCommandPacketType }
    var isRunCommandRequestPacket: Bool { return self.type == DataPacket.runCommandRequestPacketType }
    
    
    // MARK: Public static methods
    
    static func runCommandRequestPacket(key: String) -> DataPacket {
        return DataPacket(type: runCommandRequestPacketType, body: [RunCommandProperty.key: key as AnyObject])
    }
    
    static func runCommandListRequestPacket() -> DataPacket {
        return DataPacket(type: runCommandRequestPacketType, body: [RunCommandProperty.requestCommandList: true as AnyObject])
    }
    
    /// Command list advertised to the remote device. `canAddCommand` tells it this Mac answers `setup`
    /// requests by opening its command editor.
    static func runCommandListPacket(commandList: [String: [String: String]]) -> DataPacket {
        let commandListString = try? JSONSerialization.data(withJSONObject: commandList)
        let commandListJSON = commandListString.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return DataPacket(type: runCommandPacketType, body: [
            RunCommandProperty.commandList: commandListJSON as AnyObject,
            RunCommandProperty.canAddCommand: true as AnyObject
        ])
    }
    
    static func runCommandStartedPacket(id: Int, command: String) -> DataPacket {
        return DataPacket(type: runCommandOutputPacketType, body: [
            RunCommandProperty.commandStarted: true as AnyObject,
            RunCommandProperty.command: command as AnyObject,
            RunCommandProperty.id: NSNumber(value: id)
        ])
    }
    
    static func runCommandOutputPacket(id: Int, stdout: [String], stderr: [String]) -> DataPacket {
        return DataPacket(type: runCommandOutputPacketType, body: [
            RunCommandProperty.commandOutput: true as AnyObject,
            RunCommandProperty.stdout: stdout as AnyObject,
            RunCommandProperty.stderr: stderr as AnyObject,
            RunCommandProperty.id: NSNumber(value: id)
        ])
    }
    
    static func runCommandFinishedPacket(id: Int, exitCode: Int) -> DataPacket {
        return DataPacket(type: runCommandOutputPacketType, body: [
            RunCommandProperty.commandFinished: true as AnyObject,
            RunCommandProperty.success: (exitCode == 0) as AnyObject,
            RunCommandProperty.exitCode: NSNumber(value: exitCode),
            RunCommandProperty.id: NSNumber(value: id)
        ])
    }
    
    
    // MARK: Public methods
    
    func getCommandList() throws -> [String: [String: String]]? {
        try self.validateRunCommandType()
        guard body.keys.contains(RunCommandProperty.commandList) else { return nil }
        guard let commandListString = body[RunCommandProperty.commandList] as? String else { throw RunCommandError.invalidCommandList }
        guard let data = commandListString.data(using: .utf8) else { throw RunCommandError.invalidCommandList }
        return try JSONSerialization.jsonObject(with: data) as? [String: [String: String]]
    }
    
    func getRequestKey() throws -> String? {
        try self.validateRunCommandRequestType()
        guard body.keys.contains(RunCommandProperty.key) else { return nil }
        guard let value = body[RunCommandProperty.key] as? String else { throw RunCommandError.invalidKey }
        return value
    }
    
    func isRequestingCommandList() throws -> Bool {
        try self.validateRunCommandRequestType()
        guard body.keys.contains(RunCommandProperty.requestCommandList) else { return false }
        guard let value = body[RunCommandProperty.requestCommandList] as? NSNumber else { throw RunCommandError.invalidRequestFlag }
        return value.boolValue
    }
    
    var isSetupRequest: Bool {
        return isRunCommandRequestPacket && (body[RunCommandProperty.setup] as? NSNumber)?.boolValue == true
    }
    
    var isStopRequest: Bool {
        return isRunCommandRequestPacket && (body[RunCommandProperty.stop] as? NSNumber)?.boolValue == true
    }
    
    func validateRunCommandType() throws {
        guard self.isRunCommandPacket else { throw RunCommandError.wrongType }
    }
    
    func validateRunCommandRequestType() throws {
        guard self.isRunCommandRequestPacket else { throw RunCommandError.wrongType }
    }
}
