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
//
// Portions of this file are derived from the SwiftNIO HTTP/2 multiplexer (Apache License v2.0),
// adapted for the swift-libp2p mock muxer.

/// A minimal intrusive linked list for storing child channels awaiting `channelReadComplete`.
internal struct MockMuxStreamChannelList {
    private var head: MockMuxAbstractChannel?
    private var tail: MockMuxAbstractChannel?
}

/// A node embedded in each child channel so it can participate in `MockMuxStreamChannelList`.
internal struct MockMuxStreamChannelListNode {
    fileprivate enum ListState {
        case inList(next: MockMuxAbstractChannel?)
        case notInList
    }

    fileprivate var state: ListState = .notInList

    init() {}
}

extension MockMuxStreamChannelList {
    mutating func append(_ element: MockMuxAbstractChannel) {
        precondition(!element.inList)

        guard case .notInList = element.streamChannelListNode.state else {
            preconditionFailure("Appended an element already in a list")
        }

        element.streamChannelListNode.state = .inList(next: nil)

        if let tail = self.tail {
            tail.streamChannelListNode.state = .inList(next: element)
            self.tail = element
        } else {
            assert(self.head == nil)
            self.head = element
            self.tail = element
        }
    }

    mutating func removeFirst() -> MockMuxAbstractChannel? {
        guard let head = self.head else {
            assert(self.tail == nil)
            return nil
        }

        guard case .inList(let next) = head.streamChannelListNode.state else {
            preconditionFailure("Popped an element not in a list")
        }

        self.head = next
        if self.head == nil {
            assert(self.tail == head)
            self.tail = nil
        }

        head.streamChannelListNode = .init()
        return head
    }

    mutating func removeAll() {
        while self.removeFirst() != nil {}
    }
}

extension MockMuxStreamChannel {
    /// Whether this element is currently in a list.
    internal var inList: Bool {
        switch self.streamChannelListNode.state {
        case .inList:
            return true
        case .notInList:
            return false
        }
    }
}
