//
//  NetworkUtils.swift
//  Soduto
//
//  Created by Giedrius Stanevičius on 2016-11-27.
//  Copyright © 2016 Soduto. All rights reserved.
//

import Foundation
import NIOCore

public struct NetworkUtils {
    
    // MARK: - NIO SocketAddress with IPv6 Scope ID Support
    
    /// Creates a NIO SocketAddress from an IP address string, with proper support for
    /// IPv6 link-local addresses that include scope IDs (e.g., "fe80::1234%en0").
    ///
    /// Standard NIO `SocketAddress(ipAddress:port:)` uses `inet_pton` which doesn't
    /// support scope IDs. This function uses `getaddrinfo` which properly handles them.
    ///
    /// - Parameters:
    ///   - address: IP address string (IPv4, IPv6, or IPv6 with scope ID)
    ///   - port: Port number
    /// - Returns: NIO SocketAddress, or nil if the address couldn't be parsed
    public static func createSocketAddress(address: String, port: Int) -> NIOCore.SocketAddress? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC      // Allow both IPv4 and IPv6
        hints.ai_socktype = 0            // Unspecified: allow both UDP and TCP
        hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV  // Don't do DNS or service-name lookups
        
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(address, String(port), &hints, &result)
        
        guard status == 0, let info = result else {
            return nil
        }
        defer { freeaddrinfo(result) }
        
        // Convert the resolved address to NIO SocketAddress
        guard let sockaddr = info.pointee.ai_addr else { return nil }
        
        if info.pointee.ai_family == AF_INET6 {
            // IPv6 - includes proper scope ID handling
            let sockaddr6 = sockaddr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
            return NIOCore.SocketAddress(sockaddr6)
        } else if info.pointee.ai_family == AF_INET {
            // IPv4
            let sockaddr4 = sockaddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            return NIOCore.SocketAddress(sockaddr4)
        }
        
        return nil
    }
    
    // MARK: Types
    
    public enum NetworkError: Error {
        case routeSysctlEstimateFailed
        case routingTableRetrievalFailed
    }
    
    public struct ArpInfo {
        let sin_addr: in_addr
        let ipAddressString: String
        let hwAddressString: String?
    }
    
    public struct LocalAddressInfo {
        let ip: SocketAddress
        let netmask: SocketAddress
        let ipString: String
        let netmaskString: String
    }
    
    
    // Public static methods
    
    // Routing-socket layouts from <net/route.h>, <netinet/if_ether.h> and <net/if_dl.h>, which aren't
    // part of Swift's Darwin module. Each ARP entry is an rt_msghdr followed by a sockaddr_inarp (same
    // size and sin_addr offset as sockaddr_in) and a sockaddr_dl.
    private static let routeMessageHeaderSize = 92        // sizeof(struct rt_msghdr)
    private static let netRouteFlags: Int32 = 2           // NET_RT_FLAGS
    private static let routeFlagLinkLayerInfo: Int32 = 0x400  // RTF_LLINFO
    private static let linkLayerNameLengthOffset = 5      // sockaddr_dl.sdl_nlen
    private static let linkLayerAddressLengthOffset = 6   // sockaddr_dl.sdl_alen
    private static let linkLayerDataOffset = 8            // sockaddr_dl.sdl_data
    
    /// The IPv4 entries of the ARP table, with their hardware addresses when resolved
    public static func accessibleIPv4Addresses() throws -> [ArpInfo] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, netRouteFlags, routeFlagLinkLayerInfo]
        
        // The table can grow between the size estimate and the read; retry a few times
        var buffer: [UInt8] = []
        var tableSize = 0
        var attempts = 3
        while true {
            var needed = 0
            guard sysctl(&mib, u_int(mib.count), nil, &needed, nil, 0) >= 0 else { throw NetworkError.routeSysctlEstimateFailed }
            buffer = [UInt8](repeating: 0, count: needed)
            tableSize = needed
            if sysctl(&mib, u_int(mib.count), &buffer, &tableSize, nil, 0) >= 0 { break }
            attempts -= 1
            guard attempts > 0 else { throw NetworkError.routingTableRetrievalFailed }
        }
        
        var addresses: [ArpInfo] = []
        buffer.withUnsafeBytes { table in
            var position = 0
            while position + routeMessageHeaderSize + MemoryLayout<sockaddr_in>.size <= tableSize {
                let messageLength = Int(table.loadUnaligned(fromByteOffset: position, as: UInt16.self))
                guard messageLength > 0 else { break }
                defer { position += messageLength }
                
                let inetOffset = position + routeMessageHeaderSize
                let inet = table.loadUnaligned(fromByteOffset: inetOffset, as: sockaddr_in.self)
                var address = inet.sin_addr
                var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                let ipAddressString = inet_ntop(AF_INET, &address, &text, socklen_t(text.count)).map { String(cString: $0) } ?? "0.0.0.0"
                
                var hwAddressString: String? = nil
                let linkOffset = inetOffset + MemoryLayout<sockaddr_in>.size
                if linkOffset + linkLayerDataOffset <= position + messageLength {
                    let nameLength = Int(table[linkOffset + linkLayerNameLengthOffset])
                    let addressLength = Int(table[linkOffset + linkLayerAddressLengthOffset])
                    let start = linkOffset + linkLayerDataOffset + nameLength
                    if addressLength == 6, start + 6 <= position + messageLength {
                        hwAddressString = (0..<6).map { String(format: "%x", table[start + $0]) }.joined(separator: ":")
                    }
                }
                addresses.append(ArpInfo(sin_addr: inet.sin_addr, ipAddressString: ipAddressString, hwAddressString: hwAddressString))
            }
        }
        return addresses
    }
    
    public static func hwAddress(for socketAddress: SocketAddress) -> String? {
        guard socketAddress.isIPv4 else { return nil }
        
        let arpInfos = (try? accessibleIPv4Addresses()) ?? []
        for arpInfo in arpInfos {
            if arpInfo.sin_addr.s_addr == socketAddress.ipv4.sin_addr.s_addr {
                return arpInfo.hwAddressString
            }
        }
        return nil
    }
    
    /// Sends one empty UDP datagram (to the discard port) to every host on the local IPv4 subnets, at
    /// most 254 per interface, without waiting for answers. Nothing needs to reply: sending makes macOS
    /// resolve each address over ARP, which fills the ARP table that directed announcements use.
    public static func pingLocalNetwork() {
        let socketHandle = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socketHandle >= 0 else { return }
        defer { close(socketHandle) }
        _ = fcntl(socketHandle, F_SETFL, fcntl(socketHandle, F_GETFL) | O_NONBLOCK)
        let discardPort = in_port_t(9).bigEndian
        
        for localAddressInfo in localAddresses() {
            guard localAddressInfo.ip.isIPv4, localAddressInfo.netmask.isIPv4 else { continue }
            let netMask = localAddressInfo.netmask.ipv4.sin_addr.s_addr
            let networkPrefix = localAddressInfo.ip.ipv4.sin_addr.s_addr & netMask
            for i in 1 ... 254 {
                let hostPart = UInt32(i).bigEndian
                guard (hostPart & netMask) == 0 else { break }
                var target = localAddressInfo.ip.ipv4
                target.sin_addr.s_addr = networkPrefix | hostPart
                target.sin_port = discardPort
                _ = withUnsafePointer(to: &target) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(socketHandle, nil, 0, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
    }
    
    // Get the local ip addresses used by this node
    static func localAddresses() -> [LocalAddressInfo] {
        var addresses: [LocalAddressInfo] = []
        
        // Get list of all interfaces on the local machine:
        var ifaddr : UnsafeMutablePointer<ifaddrs>? = nil
        if getifaddrs(&ifaddr) == 0 {
            
            var ptr = ifaddr;
            while ptr != nil {
                
                let flags = Int32((ptr?.pointee.ifa_flags)!)
                var addr = ptr?.pointee.ifa_addr.pointee
                
                // Check for running IPv4 interfaces. Skip the loopback interface.
                // Note: IPv6 is excluded because all consumers only use IPv4 for
                // broadcast address calculation, and the sockaddr copy-by-value
                // truncates IPv6 addresses (sockaddr_in6 is 28 bytes vs 16 for sockaddr).
                if (flags & (IFF_UP|IFF_RUNNING|IFF_LOOPBACK)) == (IFF_UP|IFF_RUNNING) {
                    if addr?.sa_family == UInt8(AF_INET) {
                        
                        // Convert interface address to a human readable string:
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        if (getnameinfo(&addr!, socklen_t((addr?.sa_len)!), &hostname, socklen_t(hostname.count),
                                        nil, socklen_t(0), NI_NUMERICHOST) == 0) {
                            if let address = String.init(validatingUTF8:hostname) {
                                
                                var net = ptr?.pointee.ifa_netmask.pointee
                                var netmaskName = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                                getnameinfo(&net!, socklen_t((net?.sa_len)!), &netmaskName, socklen_t(netmaskName.count),
                                            nil, socklen_t(0), NI_NUMERICHOST)// == 0
                                if let netmask = String.init(validatingUTF8:netmaskName) {
                                    addresses.append(LocalAddressInfo(ip: SocketAddress(addr: addr), netmask: SocketAddress(addr: net), ipString: address, netmaskString: netmask))
                                }
                            }
                        }
                    }
                }
                ptr = ptr?.pointee.ifa_next
            }
            freeifaddrs(ifaddr)
        }
        return addresses
    }
    
}
