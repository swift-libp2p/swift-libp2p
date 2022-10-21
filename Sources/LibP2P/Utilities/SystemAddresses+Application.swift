//
//  SystemAddresses+Application.swift
//  
//
//  Created by Brandon Toms on 10/21/22.
//

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
