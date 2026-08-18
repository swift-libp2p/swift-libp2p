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

import LibP2P

// MARK: - Wire model
//
// `MockMux` is the wire-capable muxer used by the module-conformance harnesses. It exists so a
// Security or Transport module can be exercised over a *real* loopback socket with a known-good muxer
// partner, without pulling a production muxer package (mplex / yamux) into `LibP2PTesting` — which
// would create a circular package dependency (those packages depend on `LibP2P`).
//
// The framing below is deliberately mplex-shaped (uVarInt `header || length || payload`, where
// `header = streamID << 3 | flag`). It is intentionally kept simple: the harness only ever drives a
// single logical stream at a time, so there is no flow-control / windowing. See `MockMuxer.swift` for
// the registrable `MuxerUpgrader`.

/// The per-frame flag, encoded into the low 3 bits of the frame header.
internal enum MockMuxFlag: UInt64 {
    case NewStream = 0
    case MessageReceiver = 1
    case MessageInitiator = 2
    case CloseReceiver = 3
    case CloseInitiator = 4
    case ResetReceiver = 5
    case ResetInitiator = 6
}

/// A stream identifier. The `initiator` flag records which side opened the stream (mirroring mplex,
/// where the same numeric id can be used independently by either peer).
internal struct MockMuxStreamID: Hashable, Sendable {
    let id: UInt64
    let initiator: Bool

    init(id: UInt64, flag: MockMuxFlag) {
        self.id = id
        switch flag {
        case .NewStream, .MessageInitiator, .CloseInitiator, .ResetInitiator:
            self.initiator = false
        default:
            self.initiator = true
        }
    }

    init(id: UInt64, mode: LibP2P.Mode) {
        self.id = id
        self.initiator = mode == .initiator
    }

    var description: String {
        "[\(id)][\(self.initiator ? "Outbound" : "Inbound")]"
    }
}

/// A single decoded / to-be-encoded frame.
internal struct MockMuxFrame: Equatable, Sendable {
    /// The stream this frame belongs to.
    let streamID: MockMuxStreamID

    /// The payload of this frame.
    let payload: FramePayload

    enum FramePayload: Equatable {
        case inboundData(ByteBuffer)
        case outboundData(ByteBuffer)
        case close
        case reset
        case newStream

        var bytes: [UInt8] {
            switch self {
            case .inboundData(let payload):
                return [UInt8](payload.readableBytesView)
            case .outboundData(let payload):
                return [UInt8](payload.readableBytesView)
            default:
                return []
            }
        }

        var buffer: ByteBuffer {
            switch self {
            case .inboundData(let payload):
                return payload
            case .outboundData(let payload):
                return payload
            default:
                return ByteBuffer()
            }
        }
    }

    var flag: MockMuxFlag {
        switch payload {
        case .newStream:
            return .NewStream
        case .inboundData, .outboundData:
            return streamID.initiator ? .MessageInitiator : .MessageReceiver
        case .close:
            return streamID.initiator ? .CloseInitiator : .CloseReceiver
        case .reset:
            return streamID.initiator ? .ResetInitiator : .ResetReceiver
        }
    }

    /// The raw message bytes carried by this frame (empty for control frames).
    func messageBytes() -> ByteBuffer {
        self.payload.buffer
    }
}

extension MockMuxFrame.FramePayload {
    /// A rough per-frame size estimate (header + payload), used only for buffering heuristics.
    var estimatedFrameSize: Int {
        let frameHeaderSize = 1
        switch self {
        case .inboundData(let d):
            return d.readableBytes + frameHeaderSize
        default:
            return frameHeaderSize
        }
    }
}
