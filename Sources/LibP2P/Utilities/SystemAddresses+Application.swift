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
}
