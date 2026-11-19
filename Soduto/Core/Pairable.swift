//
//  Pairable.swift
//  Soduto
//
//  Created by Giedrius Stanevičius on 2016-09-05.
//  Copyright © 2016 Soduto. All rights reserved.
//

import Foundation

public enum PairingStatus: Int, Sendable {
    case Unpaired
    case Requested
    case RequestedByPeer
    case Paired
}

public struct PairingRequest: Sendable {
    /// The link the request arrived on
    public let link: DeviceLink
}

/// Pairing events a link reports to its owner (the `Device`).
public protocol DeviceLinkPairingDelegate: AnyObject {
    func link(_ link: DeviceLink, receivedPairingRequest request: PairingRequest)
    func link(_ link: DeviceLink, pairingFailed error: Error)
    func link(_ link: DeviceLink, pairingStatusChanged status: PairingStatus)
}

public protocol Pairable: AnyObject {
    
    var pairingDelegate: DeviceLinkPairingDelegate? { get set }
    var pairingStatus: PairingStatus { get }
    
    func requestPairing()
    func acceptPairing()
    func declinePairing()
    func unpair()
    func updatePairingStatus(globalStatus: PairingStatus)
}

public protocol PairableClass: AnyObject, Pairable {
}
