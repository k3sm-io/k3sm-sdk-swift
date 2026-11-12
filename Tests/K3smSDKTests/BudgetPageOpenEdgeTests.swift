/*
Copyright The k3sm Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

import Darwin
import Foundation
@testable import K3smSDK
import Testing

private let edgeFixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Fixtures/page/darwin.v1.page")

/// A UUID directory under the system temp directory, removed when the body
/// returns or throws.
private func withTempDir<T>(_ body: (URL) throws -> T) throws -> T {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    return try body(dir)
}

@Suite struct BudgetPageOpenEdgeTests {
    @Test func emptyRegularFileIsTruncated() throws {
        try withTempDir { dir in
            let path = dir.appendingPathComponent("empty.v1.page").path
            #expect(FileManager.default.createFile(atPath: path, contents: Data()))
            #expect(throws: BudgetError.truncated) { try BudgetPage.open(path: path) }
        }
    }

    @Test func symlinkLoopForwardsELOOP() throws {
        try withTempDir { dir in
            let a = dir.appendingPathComponent("a").path
            let b = dir.appendingPathComponent("b").path
            try FileManager.default.createSymbolicLink(atPath: a, withDestinationPath: b)
            try FileManager.default.createSymbolicLink(atPath: b, withDestinationPath: a)
            #expect(throws: BudgetError.notFound(errno: ELOOP)) { try BudgetPage.open(path: a) }
        }
    }

    @Test func overlongPathForwardsENAMETOOLONG() {
        let path = String(repeating: "x", count: 5000)
        #expect(throws: BudgetError.notFound(errno: ENAMETOOLONG)) { try BudgetPage.open(path: path) }
    }

    /// The stale bound at a writer period other than 1. The page is the
    /// bundled fixture with its writer-period and observed-at words patched.
    /// The age is deterministic: `read(now:)` takes the clock as an argument,
    /// so the exact bound (age == 3 periods fresh, one second more stale) is
    /// pinned with no dependence on the wall clock.
    @Test(arguments: [Int64(2), 3, 7])
    func staleBoundScalesWithWriterPeriod(period: Int64) throws {
        let observedAt: Int64 = 1_700_000_000
        var bytes = try Data(contentsOf: edgeFixture)
        bytes.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: period.littleEndian, toByteOffset: PageLayout.writerPeriodSeconds, as: Int64.self)
            raw.storeBytes(of: observedAt.littleEndian, toByteOffset: PageLayout.observedAt, as: Int64.self)
        }
        try withTempDir { dir in
            let path = dir.appendingPathComponent("period.v1.page").path
            try bytes.write(to: URL(fileURLWithPath: path))
            let page = try BudgetPage.open(path: path)
            let bound = observedAt + PageLayout.staleFactor * period
            let fresh = try page.read(now: bound).get()
            #expect(fresh.writerPeriodSeconds == period)
            #expect(fresh.observedAt == observedAt)
            #expect(throws: BudgetError.stale) { try page.read(now: bound + 1).get() }
        }
    }
}
