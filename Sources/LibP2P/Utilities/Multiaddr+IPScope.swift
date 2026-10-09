//===----------------------------------------------------------------------===//
//
// This source file is part of the swift-libp2p open source project
//
// Copyright (c) 2022-2026 swift-libp2p project authors
// Licensed under MIT
//
// See LICENSE for license information
// See CONTRIBUTORS for the list of swift-libp2p project authors
//
// SPDX-License-Identifier: MIT
//
//===----------------------------------------------------------------------===//

public import Multiaddr
import NIOCore

/// The routing scope of an IP address.
///
/// - Note: https://en.wikipedia.org/wiki/IP_address#
public enum IPScope: String, Sendable, Hashable, CaseIterable {

    /// `0.0.0.0` / `::`, a bind address
    case unspecified

    /// `127.0.0.0/8` / `::1`, a loopback address
    case loopback

    /// RFC 1918 (`10/8`, `172.16/12`, `192.168/16`) and the deprecated IPv6 site-local range (`fec0::/10`).
    case `private`

    /// RFC 6598 carrier grade NAT space (`100.64/10`).
    case sharedAddressSpace

    /// `169.254/16` / `fe80::/10`
    case linkLocal

    /// IPv6 unique local addresses (`fc00::/7`).
    case uniqueLocal

    /// `224/4` / `ff00::/8`
    case multicast

    /// Documentation, benchmarking, "this network", broadcast and other non-routable reserved ranges.
    case reserved

    /// Globally routable.
    case `public`

    /// True for scopes that are only reachable from within a local network or host
    /// (loopback, private, shared address space, link local and unique local).
    public var isInternal: Bool {
        switch self {
        case .loopback, .private, .sharedAddressSpace, .linkLocal, .uniqueLocal: return true
        case .unspecified, .multicast, .reserved, .public: return false
        }
    }
}

extension IPScope {

    /// Classifies a textual IPv4 or IPv6 address, returns `nil` if `ip` can't be parsed.
    public init?(ipAddress ip: String) {
        if let v4 = IPScope.parseIPv4(ip) {
            self = IPScope.classify(v4: v4)
        } else if let v6 = IPScope.parseIPv6(ip) {
            self = IPScope.classify(v6: v6)
        } else {
            return nil
        }
    }

    static func parseIPv4(_ ip: String) -> [UInt8]? {
        let parts = ip.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(4)
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isASCII), let b = UInt8(part) else { return nil }
            bytes.append(b)
        }
        return bytes
    }

    static func parseIPv6(_ ip: String) -> [UInt8]? {
        // Strip any zone identifier (`fe80::1%en0`)
        let address = ip.split(separator: "%", maxSplits: 1).first.map(String.init) ?? ip
        guard address.contains(":"), let sa = try? SocketAddress(ipAddress: address, port: 0) else { return nil }
        guard case .v6(let v6) = sa else { return nil }
        return withUnsafeBytes(of: v6.address.sin6_addr) { Array($0) }
    }

    static func classify(v4 b: [UInt8]) -> IPScope {
        precondition(b.count == 4)
        switch (b[0], b[1], b[2]) {
        case (0, 0, 0) where b[3] == 0: return .unspecified
        case (0, _, _): return .reserved  // 0.0.0.0/8 "this network"
        case (127, _, _): return .loopback
        case (10, _, _): return .private
        case (172, 16...31, _): return .private
        case (192, 168, _): return .private
        case (100, 64...127, _): return .sharedAddressSpace
        case (169, 254, _): return .linkLocal
        case (192, 0, 0): return .reserved  // IETF protocol assignments
        case (192, 0, 2), (198, 51, 100), (203, 0, 113): return .reserved  // documentation
        case (198, 18...19, _): return .reserved  // benchmarking
        case (224...239, _, _): return .multicast
        case (240...255, _, _): return .reserved  // reserved + broadcast
        default: return .public
        }
    }

    static func classify(v6 b: [UInt8]) -> IPScope {
        precondition(b.count == 16)
        if b.allSatisfy({ $0 == 0 }) { return .unspecified }
        if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return .loopback }
        // IPv4 mapped (::ffff:0:0/96) and the NAT64 well known prefix (64:ff9b::/96) embed an IPv4 address.
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff {
            return classify(v4: Array(b[12..<16]))
        }
        if b[0] == 0x00 && b[1] == 0x64 && b[2] == 0xff && b[3] == 0x9b && b[4..<12].allSatisfy({ $0 == 0 }) {
            return classify(v4: Array(b[12..<16]))
        }
        if b[0] == 0xff { return .multicast }
        if b[0] == 0xfe && (b[1] & 0xc0) == 0x80 { return .linkLocal }  // fe80::/10
        if b[0] == 0xfe && (b[1] & 0xc0) == 0xc0 { return .private }  // fec0::/10 (deprecated site local)
        if (b[0] & 0xfe) == 0xfc { return .uniqueLocal }  // fc00::/7
        if b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0d && b[3] == 0xb8 { return .reserved }  // 2001:db8::/32
        if b[0] == 0x01 && b[1] == 0x00 && b[2..<8].allSatisfy({ $0 == 0 }) { return .reserved }  // 100::/64 discard
        return .public
    }
}

extension Multiaddr {

    /// The leading IP component of this multiaddr, if it starts with `/ip4` or `/ip6`.
    public var ipComponent: (codec: MultiaddrProtocol, address: String)? {
        guard let first = self.addresses.first, first.codec == .ip4 || first.codec == .ip6,
            let addr = first.addr
        else { return nil }
        return (first.codec, addr)
    }

    /// The routing scope of the leading IP component, `nil` when the multiaddr doesn't start with an IP
    /// (dns, dnsaddr, unix, onion, ...).
    public var ipScope: IPScope? {
        guard let ip = self.ipComponent else { return nil }
        return IPScope(ipAddress: ip.address)
    }

    /// True if this multiaddr is a globally routable host.
    ///
    /// - IP based addresses must be in the ``IPScope/public`` scope.
    /// - DNS based addresses are assumed to be public unless they name `localhost` or a
    ///   `.local` / `.localhost` host.
    /// - Relayed addresses are not public.
    public var isPublicAddress: Bool {
        guard !self.isRelayedAddress else { return false }
        if let scope = self.ipScope { return scope == .public }
        guard let first = self.addresses.first else { return false }
        switch first.codec {
        case .dns, .dns4, .dns6, .dnsaddr:
            guard let host = first.addr?.lowercased() else { return false }
            return !(host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local"))
        default:
            return false
        }
    }

    /// True if this multiaddr is only reachable from a local network or host, see ``IPScope/isInternal``.
    public var isPrivateAddress: Bool {
        if let scope = self.ipScope { return scope.isInternal }
        if let first = self.addresses.first, [.dns, .dns4, .dns6].contains(first.codec),
            let host = first.addr?.lowercased()
        {
            return host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local")
        }
        return false
    }

    /// True if this multiaddr routes through a circuit relay (`/p2p-circuit`).
    public var isRelayedAddress: Bool {
        self.addresses.contains { $0.codec == .p2p_circuit }
    }

    /// Returns a copy of this multiaddr with its leading IP component replaced by the leading IP component of `other`.
    ///
    /// For example `/ip4/192.168.1.2/tcp/4001`.replacingIP(with: `/ip4/1.2.3.4/tcp/55555`) == `/ip4/1.2.3.4/tcp/4001`.
    /// Returns `nil` if either multiaddr doesn't start with an IP component.
    public func replacingIP(with other: Multiaddr) -> Multiaddr? {
        guard self.ipComponent != nil, let ip = other.ipComponent else { return nil }
        guard var new = try? Multiaddr(ip.codec, address: ip.address) else { return nil }
        for component in self.addresses.dropFirst() {
            guard let next = try? new.encapsulate(proto: component.codec, address: component.addr) else { return nil }
            new = next
        }
        return new
    }
}

extension Multiaddr {
    
    /// True if this multiaddr is only reachable from a local network or host
    /// (loopback, RFC 1918, CGNAT, link local, IPv6 unique local, or `localhost`). See ``IPScope``.
    public var isInternalAddress: Bool {
        self.isPrivateAddress
    }

    /// True if this multiaddr is a globally routable host.
    public var isExternalAddress: Bool {
        self.isPublicAddress
    }

    /// True when this multiaddr's IP component is the unspecified/wildcard
    /// address (IPv4 `0.0.0.0` or IPv6 `::`). A wildcard is a *bind* address,
    /// never a dialable destination, so it must never be advertised to remote
    /// peers. Parsed via `tcpAddress` (not a substring match) so a real address
    /// like `10.0.0.0` — which *contains* the substring `0.0.0.0` — is not
    /// misclassified.
    public var isUnspecifiedAddress: Bool {
        guard let tcp = self.tcpAddress else { return false }
        return tcp.address == "0.0.0.0" || tcp.address == "::"
    }
}
