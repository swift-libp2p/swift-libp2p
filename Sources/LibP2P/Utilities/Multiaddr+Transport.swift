//===----------------------------------------------------------------------===//
//
// This source file is part of the swift-libp2p open source project
//
// Copyright (c) 2022-2025 swift-libp2p project authors
// Licensed under MIT
//
// See LICENSE for license information
// See CONTRIBUTORS for the list of swift-libp2p project authors
//
// SPDX-License-Identifier: MIT
//
//===----------------------------------------------------------------------===//

import Multiaddr

public extension Multiaddr {
    
    /// Extracts the address, port and protocol version from a Multiaddr if it is a valid TCP address
    var tcpAddress:(address:String, port:Int, ip4:Bool)? {
        var host:String? = nil
        var port:Int? = nil
        var isIP4:Bool? = nil
        
        /// If our multiaddr is using the `dnsaddr` protocol, attempt to resolve it for a tcp ipv4 address
        if self.addresses.first?.codec == .dnsaddr {
//            #if canImport(LibP2PDNSAddr)
//            return self.resolve(for: [Codecs.ip4, Codecs.tcp])?.tcpAddress
//            #endif
            print("ERROR: Can't resolve DNS Address without DNSADDR dependency")
            return nil
        }
        
        self.addresses.forEach {
            switch $0.codec {
            case .ip4:
                if let h = $0.addr {
                    host = h
                    isIP4 = true
                }
            case .ip6:
                if let h = $0.addr {
                    host = h
                    isIP4 = false
                }
            case .tcp:
                if let pStr = $0.addr, let p = Int(pStr) {
                    port = p
                }
            default:
                return
            }
        }
        
        guard let _host = host, let _port = port, let _isIP4 = isIP4, !_host.isEmpty, _port >= 0 else {
            //print("Multiaddr.tcpAddress Error: Invalid Host and/or Port values for TCP address from multiaddr:")
            //print(self)
            return nil
        }

        return (_host, _port, _isIP4)
    }
    
    /// Extracts the address, port and protocol version from a Multiaddr if it is a valid UDP address
    var udpAddress:(address:String, port:Int, ip4:Bool)? {
        var host:String? = nil
        var port:Int? = nil
        var isIP4:Bool? = nil
        
        /// If our multiaddr is using the `dnsaddr` protocol, attempt to resolve it for a tcp ipv4 address
        if self.addresses.first?.codec == .dnsaddr {
//            #if canImport(LibP2PDNSAddr)
//            return self.resolve(for: [.ip4, .udp])?.udpAddress
//            #endif
            print("Error: Can't resolve DNSAddr without LibP2PDNSAddr module")
            return nil
        }
        
        self.addresses.forEach {
            switch $0.codec {
            case .ip4:
                if let h = $0.addr {
                    host = h
                    isIP4 = true
                }
            case .ip6:
                if let h = $0.addr {
                    host = h
                    isIP4 = false
                }
            case .udp:
                if let pStr = $0.addr, let p = Int(pStr) {
                    port = p
                }
            default:
                return
            }
        }
        
        guard let _host = host, let _port = port, let _isIP4 = isIP4, !_host.isEmpty, _port >= 0 else {
            print("Multiaddr.udpAddress Error: Invalid Host and/or Port values for UDP address from multiaddr:")
            print(self)
            return nil
        }

        return (_host, _port, _isIP4)
    }
}

extension SocketAddress {
    public func toMultiaddr(proto:MultiaddrProtocol = .tcp) throws -> Multiaddr {
        var ma:Multiaddr
        if let ip = self.ipAddress {
            /// - TODO: Determine if ip4 or ip6
            switch self.protocol {
            case .inet:
                ma = try Multiaddr(.ip4, address: ip)
            case .inet6:
                ma = try Multiaddr(.ip6, address: ip)
            default:
                throw NSError(domain: "Failed to convert SocketAddress to Multiaddr", code: 0, userInfo: nil)
            }
//            if self.description.hasPrefix("[IPv6]") {
//                ma = try Multiaddr(.ip6, address: ip)
//            } else if self.description.hasPrefix("[IPv4]") {
//                ma = try Multiaddr(.ip4, address: ip)
//            } else {
//                throw NSError(domain: "Failed to convert SocketAddress to Multiaddr", code: 0, userInfo: nil)
//            }
            
            if let port = self.port {
                switch proto {
                case .tcp:
                    ma = try ma.encapsulate(proto: .tcp, address: "\(port)")
                case .udp:
                    ma = try ma.encapsulate(proto: .udp, address: "\(port)")
                default:
                    print("WARNING: Unteseted Multiaddr Protocol Encapsulation!")
                    ma = try ma.encapsulate(proto: proto, address: "\(port)")
                }
            }
            
        } else if let path = self.pathname {
            ma = try Multiaddr(.unix, address: path)
        } else {
            throw NSError(domain: "Failed to convert SocketAddress to Multiaddr", code: 0, userInfo: nil)
        }
        return ma
    }
}
