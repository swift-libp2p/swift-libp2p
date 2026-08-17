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

extension Application {
    /// This method attempts to find a System Address fro the provided device name (defaults to device 'en0')
    func getSystemAddress(forDevice name: String = "en0") throws -> NIONetworkDevice {
        let devices = try System.enumerateDevices().filter({ device in
            guard device.name == name && device.address != nil else { return false }
            guard let ma = try? device.address?.toMultiaddr().tcpAddress else { return false }

            return ma.ip4
        })
        guard let device = devices.first else { throw Errors.noAddressForDevice }
        return device
    }

    /// Returns the IPv4 address string of every non-loopback, non-link-local
    /// network interface. Used to expand an unspecified (`0.0.0.0`) listen
    /// address into one concrete multiaddr per interface, mirroring
    /// rust-libp2p's transport-level `if_watch` expansion — so the wildcard
    /// never reaches the address-advertisement path. Returns an empty array if
    /// enumeration fails or no routable interface exists; callers keep the
    /// original (wildcard) address in that case and rely on the
    /// strip-unspecified backstop at the advertise boundary.
    func getAllSystemAddresses() -> [String] {
        let devices = (try? System.enumerateDevices()) ?? []
        var seen = Set<String>()
        return devices.compactMap { device -> String? in
            guard device.address != nil else { return nil }
            guard let ma = try? device.address?.toMultiaddr().tcpAddress, ma.ip4 else { return nil }
            guard let ip = device.address?.ipAddress else { return nil }
            // Exclude loopback and IPv4 link-local (169.254.0.0/16): neither is
            // a useful address to advertise to other peers.
            if ip == "127.0.0.1" || ip.hasPrefix("169.254.") { return nil }
            return seen.insert(ip).inserted ? ip : nil
        }
    }
}
