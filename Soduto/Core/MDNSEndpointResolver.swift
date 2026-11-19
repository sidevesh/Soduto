//
//  MDNSEndpointResolver.swift
//  Soduto
//
//  Created by Sannidhya Roy on 25/02/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import Foundation
import Network
import os

protocol MDNSEndpointResolverDelegate: AnyObject {
    func mdnsEndpointResolver(_ resolver: MDNSEndpointResolver, didResolveAddress address: String, forDeviceId deviceId: String, tcpPort: UInt16)
}

/// Resolves on its own queue and reports to its delegate from there; it keeps no other mutable state.
final class MDNSEndpointResolver: @unchecked Sendable {
    private static let resolutionTimeout: TimeInterval = 5.0
    
    private let queue: DispatchQueue
    
    weak var delegate: MDNSEndpointResolverDelegate?
    
    init(queue: DispatchQueue) {
        self.queue = queue
    }
    
    func resolve(endpoint: NWEndpoint, deviceId: String, tcpPort: UInt16) {
        let parameters = NWParameters.udp
        let connection = NWConnection(to: endpoint, using: parameters)
        // Set once by whichever comes first: the connection's state handler or the timeout
        let resolutionFinished = OSAllocatedUnfairLock(initialState: false)
        /// Marks resolution finished; true only for the first caller
        let finish: @Sendable () -> Bool = {
            resolutionFinished.withLock { finished in
                defer { finished = true }
                return !finished
            }
        }
        
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                guard finish() else { return }
                guard let self = self else {
                    connection.cancel()
                    return
                }
                
                if let path = connection.currentPath,
                   let remoteEndpoint = path.remoteEndpoint,
                   let ipAddress = self.extractIPAddress(from: remoteEndpoint) {
                    Logger.network.debug("mDNS resolved \(deviceId, privacy: .public) to \(ipAddress, privacy: .public):\(tcpPort, privacy: .public)")
                    self.delegate?.mdnsEndpointResolver(self, didResolveAddress: ipAddress, forDeviceId: deviceId, tcpPort: tcpPort)
                } else {
                    Logger.network.debug("mDNS: could not extract address for \(deviceId, privacy: .public)")
                }
                
                connection.cancel()
                
            case .failed(let error):
                guard finish() else { return }
                Logger.network.debug("mDNS endpoint resolution failed for \(deviceId, privacy: .public): \(error, privacy: .public)")
                connection.cancel()
                
            case .cancelled:
                _ = finish()
                
            default:
                break
            }
        }
        
        connection.start(queue: queue)
        
        queue.asyncAfter(deadline: .now() + type(of: self).resolutionTimeout) {
            guard finish() else { return }
            Logger.network.debug("mDNS endpoint resolution timeout for \(deviceId, privacy: .public)")
            connection.cancel()
        }
    }
    
    private func extractIPAddress(from endpoint: NWEndpoint) -> String? {
        switch endpoint {
        case .hostPort(let host, _):
            switch host {
            case .ipv4(let addr):
                return "\(addr)"
            case .ipv6(let addr):
                return "\(addr)"
            default:
                return nil
            }
        default:
            return nil
        }
    }
}
