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

import LibP2PCore
import LibP2PCrypto
import LibP2PTesting
import Multiaddr
import NIOCore
import Testing

@testable import LibP2P

extension LibP2PTests {

    @Suite("RequestTargetTests")
    struct RequestTargetTests {

        static func dialableAddress() throws -> Multiaddr {
            try Multiaddr("/ip4/127.0.0.1/tcp/1234")
        }

        // MARK: - Multiaddr

        @Test("A Multiaddr target resolves to itself")
        func multiaddrResolvesToItself() async throws {
            try await withApp { app in
                let address = try Self.dialableAddress()
                let resolved = try await address.dialAddress(
                    for: app,
                    on: app.eventLoopGroup.next()
                ).get()

                #expect(resolved == address)
            }
        }

        // MARK: - PeerID

        @Test("A PeerID target resolves to an address carrying the peer's /p2p component")
        func peerIDResolutionEncapsulatesThePeer() async throws {
            try await withApp { app in
                let peer = try PeerID(.Ed25519)
                let address = try Self.dialableAddress()
                try await app.peers.add(key: peer)
                try await app.peers.add(addresses: [address], toPeer: peer)

                let resolved = try await peer.dialAddress(
                    for: app,
                    on: app.eventLoopGroup.next()
                ).get()

                #expect(try resolved.getPeerID() == peer)
                #expect(resolved.description.hasPrefix(address.description))
            }
        }

        @Test("A PeerID with no peerstore entry fails (with the peerstore's own error)")
        func peerIDWithNoAddressesFails() async throws {
            try await withApp { app in
                let peer = try PeerID(.Ed25519)

                await #expect(throws: (any Error).self) {
                    try await peer.dialAddress(for: app, on: app.eventLoopGroup.next()).get()
                }
            }
        }

        @Test("A PeerID whose addresses no transport can dial fails with .noKnownAddressesForPeer")
        func peerIDWithUndialableAddressesIsReported() async throws {
            try await withApp { app in
                let peer = try PeerID(.Ed25519)
                // The embedded TCP transport refuses ip6 for now.
                let undialable = try Multiaddr("/ip6/::1/tcp/1234")
                try await app.peers.add(key: peer)
                try await app.peers.add(addresses: [undialable], toPeer: peer)

                await #expect(throws: Application.Errors.noKnownAddressesForPeer) {
                    try await peer.dialAddress(for: app, on: app.eventLoopGroup.next()).get()
                }
            }
        }

        @Test("A PeerID resolution skips undialable addresses in favour of a dialable one")
        func peerIDResolutionPrefersADialableAddress() async throws {
            try await withApp { app in
                let peer = try PeerID(.Ed25519)
                let undialable = try Multiaddr("/ip6/::1/tcp/1234")
                let dialable = try Self.dialableAddress()
                try await app.peers.add(key: peer)
                try await app.peers.add(addresses: [undialable, dialable], toPeer: peer)

                let resolved = try await peer.dialAddress(
                    for: app,
                    on: app.eventLoopGroup.next()
                ).get()

                #expect(resolved.description.hasPrefix(dialable.description))
                #expect(try resolved.getPeerID() == peer)
            }
        }

        // MARK: - PeerInfo

        @Test("A PeerInfo target records itself in the peerstore, then resolves as its peer")
        func peerInfoInsertsThenResolves() async throws {
            try await withApp { app in
                let peer = try PeerID(.Ed25519)
                let address = try Self.dialableAddress()
                let info = PeerInfo(peer: peer, addresses: [address])

                // Nothing in the peerstore yet.
                await #expect(throws: (any Error).self) {
                    try await app.peers.getAddresses(forPeer: peer)
                }

                let resolved = try await info.dialAddress(
                    for: app,
                    on: app.eventLoopGroup.next()
                ).get()

                #expect(try resolved.getPeerID() == peer)
                // And the insert actually happened.
                let stored = try await app.peers.getAddresses(forPeer: peer)
                #expect(stored.contains(address.encapsulating(peer: peer)))
            }
        }

        // MARK: - ComprehensivePeer

        @Test("A ComprehensivePeer from the peerstore resolves to an address carrying the peer's /p2p component")
        func comprehensivePeerResolutionEncapsulatesThePeer() async throws {
            try await withApp { app in
                let peer = try PeerID(.Ed25519)
                let undialable = try Multiaddr("/ip6/::1/tcp/1234")
                let dialable = try Self.dialableAddress()
                try await app.peers.add(key: peer)
                try await app.peers.add(addresses: [undialable, dialable], toPeer: peer)

                // Get the ComprehensivePeer from the peerstore.
                let comprehensive = try await app.peers.all().first { $0.id == peer }
                let target = try #require(comprehensive)

                let resolved = try await target.dialAddress(
                    for: app,
                    on: app.eventLoopGroup.next()
                ).get()

                // Same `canDialAny` selection as the PeerID path, not the peerstore's first address.
                #expect(resolved.description.hasPrefix(dialable.description))
                #expect(try resolved.getPeerID() == peer)
            }
        }

        /// Because a `ComprehensivePeer` is assumed to have come from the peerstore, resolution
        /// delegates straight to `PeerID` and skips the peerstore insert that `PeerInfo` performs.
        @Test("A ComprehensivePeer does not insert its own addresses into the peerstore")
        func comprehensivePeerDoesNotInsertItsAddresses() async throws {
            try await withApp { app in
                let peer = try PeerID(.Ed25519)
                let address = try Self.dialableAddress()
                let target = ComprehensivePeer(id: peer, addresses: [address])

                await #expect(throws: (any Error).self) {
                    try await target.dialAddress(for: app, on: app.eventLoopGroup.next()).get()
                }

                // Unlike the PeerInfo path, the peer is still unknown to the store.
                await #expect(throws: (any Error).self) {
                    try await app.peers.getAddresses(forPeer: peer)
                }
            }
        }

        // MARK: - Overload resolution

        /// `newStream` keeps both a deprecated concrete fire-and-forget `throws` form and the new
        /// generic `async throws` form. Swift prefers concrete over generic as a tiebreaker, so this
        /// pins that `try await` still selects the async one.
        @Test("try await newStream(to:forProtocol:) selects the async generic overload")
        func awaitSelectsTheAsyncNewStreamOverload() async throws {
            try await withApp { app in
                let peer = try PeerID(.Ed25519)

                await #expect(throws: (any Error).self) {
                    try await app.newStream(to: peer, forProtocol: "/does-not-matter/1.0.0")
                }
            }
        }

        /// Same check for the closure-taking pair.
        @Test("try await newStream(to:forProtocol:closure:) selects the async generic overload")
        func awaitSelectsTheAsyncNewStreamClosureOverload() async throws {
            try await withApp { app in
                let peer = try PeerID(.Ed25519)

                await #expect(throws: (any Error).self) {
                    try await app.newStream(
                        to: peer,
                        forProtocol: "/some-protocol/1.0.0"
                    ) { req in
                        req.eventLoop.makeSucceededFuture(RawResponse(payload: ByteBuffer()))
                    }
                }
            }
        }

        /// `newRequest` resolves its target through the same path, so an unresolvable peer surfaces
        /// the resolution error promptly rather than sitting until the request timeout.
        @Test("newRequest surfaces the target resolution error for an unknown peer")
        func newRequestSurfacesResolutionFailure() async throws {
            try await withApp { app in
                let peer = try PeerID(.Ed25519)

                await #expect(throws: (any Error).self) {
                    try await app.newRequest(
                        to: peer,
                        forProtocol: "/some-protocol/1.0.0",
                        withRequest: ByteBuffer(bytes: Array("hi".utf8)),
                        withTimeout: .milliseconds(500).ciScaled
                    )
                }

                // and specifically not by timing out, a resolution failure is not a `.timedOut`.
                await #expect(throws: (any Error).self) {
                    do {
                        let _ = try await app.newRequest(
                            to: peer,
                            forProtocol: "/some-protocol/1.0.0",
                            withRequest: ByteBuffer(bytes: Array("hi".utf8)),
                            withTimeout: .milliseconds(500).ciScaled
                        )
                    } catch Application.SingleRequestError.timedOut {
                        Issue.record("Expected a resolution failure, got a request timeout")
                    }
                }
            }
        }

        /// The `noKnownAddressesForPeer` branch is reachable through the public API, which proves
        /// `newRequest` really does run the unified `canDialAny` resolution.
        @Test("newRequest reports .noKnownAddressesForPeer for an undialable peer")
        func newRequestReportsUndialablePeer() async throws {
            try await withApp { app in
                let peer = try PeerID(.Ed25519)
                let undialable = try Multiaddr("/ip6/::1/tcp/1234")
                try await app.peers.add(key: peer)
                try await app.peers.add(addresses: [undialable], toPeer: peer)

                await #expect(throws: Application.Errors.noKnownAddressesForPeer) {
                    try await app.newRequest(
                        to: peer,
                        forProtocol: "/some-protocol/1.0.0",
                        withRequest: ByteBuffer(bytes: Array("hi".utf8)),
                        withTimeout: .milliseconds(500).ciScaled
                    )
                }
            }
        }
    }
}
