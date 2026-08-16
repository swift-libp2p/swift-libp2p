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

import Foundation

/// The structured result of running a module-conformance harness.
///
/// It is deliberately framework-agnostic (no `import Testing` / `XCTest`) so it can be asserted from
/// swift-testing, XCTest, or a plain executable. A module passes iff `failures` is empty. `warnings`
/// capture non-fatal advisories — optional features a module doesn't support (e.g. a security module
/// that leaves bytes in the clear, or a muxer without observable back-pressure).
public struct ConformanceReport: Sendable, CustomStringConvertible {

    /// A single contract check, retained whether it passed or failed for a complete audit trail.
    public struct Check: Sendable {
        public let name: String
        public let passed: Bool
        public let detail: String?
    }

    /// The thing under test, e.g. `"Muxer /yamux/1.0.0"`. Used in the rendered description.
    public let subject: String

    /// Every check run, in order, pass or fail.
    public private(set) var checks: [Check] = []
    /// Hard contract violations. Must be empty for the module to be considered conformant.
    public private(set) var failures: [String] = []
    /// Non-fatal advisories / missing optional behavior.
    public private(set) var warnings: [String] = []

    /// Whether the module honored every hard contract.
    public var passed: Bool { self.failures.isEmpty }

    public init(subject: String) {
        self.subject = subject
    }

    // MARK: Recording

    /// Records a check. A failing check is also appended to `failures`.
    public mutating func check(_ name: String, _ condition: Bool, _ detail: String? = nil) {
        self.checks.append(.init(name: name, passed: condition, detail: detail))
        if !condition {
            self.failures.append(detail.map { "\(name) — \($0)" } ?? name)
        }
    }

    /// Records a passing check.
    public mutating func pass(_ name: String, _ detail: String? = nil) {
        self.check(name, true, detail)
    }

    /// Records a failing check.
    public mutating func fail(_ name: String, _ detail: String? = nil) {
        self.check(name, false, detail)
    }

    /// Records a non-fatal advisory.
    public mutating func warn(_ message: String) {
        self.warnings.append(message)
    }

    // MARK: Consumption

    /// Throws a ``ConformanceFailure`` (carrying the full report) if any hard check failed. Lets a test
    /// collapse to a single `try report.throwIfFailed()` and surface a readable message in any framework.
    public func throwIfFailed() throws {
        if !self.passed {
            throw ConformanceFailure(report: self)
        }
    }

    public var description: String {
        var lines: [String] = []
        lines.append("Conformance report — \(self.subject): \(self.passed ? "PASS" : "FAIL")")
        for c in self.checks {
            let mark = c.passed ? "✓" : "✗"
            if let detail = c.detail {
                lines.append("  \(mark) \(c.name) — \(detail)")
            } else {
                lines.append("  \(mark) \(c.name)")
            }
        }
        if !self.warnings.isEmpty {
            lines.append("  Warnings:")
            for w in self.warnings {
                lines.append("  ⚠︎ \(w)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// Error thrown by ``ConformanceReport/throwIfFailed()``; its description is the full rendered report.
public struct ConformanceFailure: Error, CustomStringConvertible {
    public let report: ConformanceReport
    public var description: String { self.report.description }
}
