//
//  Multiaddr+Transport.swift
//  
//
//  Created by Brandon Toms on 5/1/22.
//

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
