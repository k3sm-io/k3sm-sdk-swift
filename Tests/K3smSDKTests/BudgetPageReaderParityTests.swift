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
import Synchronization
import Testing

// Reader cases the C++ SDK's reader_test.cpp and torn_test.cpp cover and
// BudgetPageReaderTests does not. The helpers of that file are private to
// it, so the few this suite needs have small local equivalents here.

private let parityFixtureDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Fixtures/page")

private func parityFixture(_ name: String) -> String { parityFixtureDir.appendingPathComponent(name).path }

/// A UUID-named directory under the system temp directory; the caller
/// removes it with a `defer` placed right after this call.
private func parityTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("k3sm-sdk-parity-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// The darwin fixture's observedAt word, so a read at it is fresh.
private func fixtureObservedAt() throws -> Int64 {
    let bytes = try Data(contentsOf: URL(fileURLWithPath: parityFixture("darwin.v1.page")))
    let word = bytes[PageLayout.observedAt..<PageLayout.observedAt + 8].withUnsafeBytes {
        $0.loadUnaligned(as: UInt64.self)
    }
    return Int64(bitPattern: UInt64(littleEndian: word))
}

/// A copy of the darwin fixture in its own temp directory, with a writable
/// shared mapping of it standing in for the writer.
private final class ParityPage {
    let dir: URL
    let path: String
    let base: UnsafeMutableRawPointer
    private let fd: Int32

    init(edit: (UnsafeMutableRawPointer) -> Void = { _ in }) throws {
        dir = try parityTempDir()
        path = dir.appendingPathComponent("budget.v1.page").path
        do {
            try FileManager.default.copyItem(atPath: parityFixture("darwin.v1.page"), toPath: path)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        fd = open(path, O_RDWR)
        guard fd >= 0, let m = mmap(nil, PageLayout.pageSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0), m != MAP_FAILED else {
            if fd >= 0 { close(fd) }
            try? FileManager.default.removeItem(at: dir)
            throw POSIXError(.EIO)
        }
        base = m
        edit(base)
    }

    deinit {
        munmap(base, PageLayout.pageSize)
        close(fd)
        try? FileManager.default.removeItem(at: dir)
    }

    private func word(_ offset: Int) -> UnsafeMutablePointer<Atomic<UInt64>> {
        (base + offset).assumingMemoryBound(to: Atomic<UInt64>.self)
    }

    func store(_ offset: Int, _ value: UInt64) { word(offset).pointee.store(value, ordering: .releasing) }
    func load(_ offset: Int) -> UInt64 { word(offset).pointee.load(ordering: .acquiring) }

    func read(now: Int64) throws -> Result<BudgetSnapshot, BudgetError> {
        try BudgetPage.open(path: path).read(now: now)
    }
}

private func put(_ base: UnsafeMutableRawPointer, _ offset: Int, _ value: UInt64) {
    base.storeBytes(of: value.littleEndian, toByteOffset: offset, as: UInt64.self)
}

@Suite struct BudgetPageReaderParityTests {
    /// A structural code one past its table is a value this reader cannot
    /// name: the read is an ABI mismatch, not a guess.
    @Test func unknownStructuralCodeIsAbiMismatch() throws {
        let now = try fixtureObservedAt()
        let slot1 = PageLayout.signals + PageLayout.signalStride
        let cases: [(name: String, offset: Int, code: Int)] = [
            ("level", PageLayout.level, PageLayout.levelCodes.count + 1),
            ("signal id", slot1, PageLayout.signalCodes.count + 1),
            ("sharedWith", PageLayout.signals + 152, PageLayout.signalCodes.count + 1),
            ("killMode.mode", PageLayout.killModeMode, PageLayout.killModeCodes.count + 1),
            ("recommendation.basis", PageLayout.recommendationBasis, PageLayout.signalCodes.count + 1),
            ("counter band", PageLayout.counters + PageLayout.counterStride, PageLayout.bandCodes.count + 1),
        ]
        // The baseline reads, so each mismatch below is the edit's alone.
        #expect(throws: Never.self) { try ParityPage().read(now: now).get() }
        for c in cases {
            let page = try ParityPage { put($0, c.offset, UInt64(c.code)) }
            #expect(throws: BudgetError.abiMismatch, "\(c.name) = \(c.code)") { try page.read(now: now).get() }
        }
    }

    /// The platform and the admit-reason signal are structural codes too: one
    /// past each table is an ABI mismatch, not an unknown value.
    @Test func unknownPlatformAndAdmitReasonSignalAreAbiMismatch() throws {
        let now = try fixtureObservedAt()
        let cases: [(name: String, offset: Int, code: Int)] = [
            ("platform", PageLayout.platform, PageLayout.platformCodes.count + 1),
            ("admitReasonSignal", PageLayout.admitReasonSignal, PageLayout.signalCodes.count + 1),
        ]
        #expect(throws: Never.self) { try ParityPage().read(now: now).get() }
        for c in cases {
            let page = try ParityPage { put($0, c.offset, UInt64(c.code)) }
            #expect(throws: BudgetError.abiMismatch, "\(c.name) = \(c.code)") { try page.read(now: now).get() }
        }
    }

    /// A producer-vocabulary code this reader does not know reads as the
    /// type's unknown value and the read succeeds.
    @Test func unknownVocabularyCodeReadsUnknown() throws {
        let page = try ParityPage { base in
            put(base, PageLayout.signals + 136, 99)
            put(base, PageLayout.signals + 144, 99)
            put(base, PageLayout.killModeReason, 99)
        }
        let s = try page.read(now: try fixtureObservedAt()).get()
        #expect(s.signals[0].trend == .unknown)
        #expect(s.signals[0].limitingResource == .unknown)
        #expect(s.killMode.reason == .unknown)
    }

    /// An empty slot in the middle of the signal or counter table is
    /// skipped; the filled slots keep their order.
    @Test func emptySlotInTheMiddleIsSkipped() throws {
        let now = try fixtureObservedAt()
        let want = try ParityPage().read(now: now).get()
        try #require(want.signals.count >= 3)
        try #require(want.counters.count == 3)
        let page = try ParityPage { base in
            for i in stride(from: 0, to: PageLayout.signalStride, by: 8) {
                put(base, PageLayout.signals + PageLayout.signalStride + i, 0)
            }
            for i in stride(from: 0, to: PageLayout.counterStride, by: 8) {
                put(base, PageLayout.counters + PageLayout.counterStride + i, 0)
            }
        }
        let s = try page.read(now: now).get()
        var signals = want.signals
        signals.remove(at: 1)
        var counters = want.counters
        counters.remove(at: 1)
        #expect(s.signals == signals)
        #expect(s.counters == counters)
        #expect(s.signals[1].id == .memorySwap)
        #expect(s.counters.map(\.band) == [.critical, .batch])
    }

    /// The node name may be 253 bytes; 254 is corrupt.
    @Test func nodeNameLen253Reads254Corrupt() throws {
        let now = try fixtureObservedAt()
        let ok = try ParityPage { base in
            for i in 0..<PageLayout.maxNodeNameBytes { base.storeBytes(of: UInt8(ascii: "a"), toByteOffset: PageLayout.nodeName + i, as: UInt8.self) }
            put(base, PageLayout.nodeNameLen, 253)
        }
        let s = try ok.read(now: now).get()
        #expect(s.nodeName == String(repeating: "a", count: 253))

        let long = try ParityPage { base in
            for i in 0..<PageLayout.maxNodeNameBytes + 1 { base.storeBytes(of: UInt8(ascii: "a"), toByteOffset: PageLayout.nodeName + i, as: UInt8.self) }
            put(base, PageLayout.nodeNameLen, 254)
        }
        #expect(throws: BudgetError.corrupt) { try long.read(now: now).get() }
    }

    /// A field the reader must have and cannot use is corrupt: a node name
    /// that is not UTF-8, a writer period below one, a zero platform or
    /// level code, and a set signal id with a zero unit.
    @Test func invalidRequiredFieldIsCorrupt() throws {
        let now = try fixtureObservedAt()
        let cases: [(name: String, edit: (UnsafeMutableRawPointer) -> Void)] = [
            ("node name not UTF-8", { base in
                base.storeBytes(of: UInt8(0xFF), toByteOffset: PageLayout.nodeName, as: UInt8.self)
                base.storeBytes(of: UInt8(0xFE), toByteOffset: PageLayout.nodeName + 1, as: UInt8.self)
                put(base, PageLayout.nodeNameLen, 2)
            }),
            ("writer period 0", { put($0, PageLayout.writerPeriodSeconds, 0) }),
            ("writer period -1", { put($0, PageLayout.writerPeriodSeconds, UInt64(bitPattern: -1)) }),
            ("platform 0", { put($0, PageLayout.platform, 0) }),
            ("level 0", { put($0, PageLayout.level, 0) }),
            ("signal unit 0", { put($0, PageLayout.signals + 8, 0) }),
        ]
        // The baseline reads and its first signal slot is set, so each
        // corrupt read below is the edit's alone.
        let want = try ParityPage().read(now: now).get()
        try #require(!want.signals.isEmpty)
        for c in cases {
            let page = try ParityPage(edit: c.edit)
            #expect(throws: BudgetError.corrupt, "\(c.name)") { try page.read(now: now).get() }
        }
    }

    /// The seqlock bound is exact: a writer that settles in time for the
    /// last allowed attempt reads, one that settles an attempt later is torn.
    @Test func tornBoundaryIsExact() throws {
        let now = try fixtureObservedAt()
        let scratch = try ParityPage()
        let page = try BudgetPage.open(path: scratch.path)
        let last = PageLayout.readerRetries - 1

        // Mid-write (odd seq) through every attempt but the last; the write
        // finishes after attempt last - 1, so the last attempt reads it.
        scratch.store(PageLayout.seq, scratch.load(PageLayout.seq) | 1)
        var attempts: [Int] = []
        let settled = page.read(now: now) { attempt in
            attempts.append(attempt)
            if attempt == last - 1 { scratch.store(PageLayout.seq, scratch.load(PageLayout.seq) + 1) }
        }
        let s = try settled.get()
        #expect(s.seq == scratch.load(PageLayout.seq))
        #expect(s.seq % 2 == 0)
        #expect(attempts == Array(0...last))

        // The same writer finishing one attempt later: torn.
        scratch.store(PageLayout.seq, scratch.load(PageLayout.seq) + 1)
        attempts = []
        let late = page.read(now: now) { attempt in
            attempts.append(attempt)
            if attempt == last { scratch.store(PageLayout.seq, scratch.load(PageLayout.seq) + 1) }
        }
        #expect(throws: BudgetError.torn) { try late.get() }
        #expect(attempts == Array(0...last))

        // A writer that publishes during every attempt but the last reads on
        // the last; one that publishes during every attempt is torn.
        let moving = page.read(now: now) { attempt in
            if attempt < last { scratch.store(PageLayout.seq, scratch.load(PageLayout.seq) + 2) }
        }
        #expect(try moving.get().seq == scratch.load(PageLayout.seq))
        attempts = []
        let always = page.read(now: now) { attempt in
            attempts.append(attempt)
            scratch.store(PageLayout.seq, scratch.load(PageLayout.seq) + 2)
        }
        #expect(throws: BudgetError.torn) { try always.get() }
        #expect(attempts.count == PageLayout.readerRetries)
    }

    /// A page that does not decode is corrupt however old it is: the decode
    /// is checked before staleness.
    @Test func corruptBeatsStale() throws {
        let page = try ParityPage { put($0, PageLayout.gpuPresent, 2) }
        let far = try fixtureObservedAt() + 1_000_000
        #expect(throws: BudgetError.corrupt) { try page.read(now: far).get() }
        #expect(throws: BudgetError.corrupt) { try page.read(now: Int64.max).get() }
        // The unedited page at the same instant is stale, so the edit is what
        // turns stale into corrupt.
        #expect(throws: BudgetError.stale) { try ParityPage().read(now: far).get() }
    }

    /// A symlink at the path is followed: to the fixture it reads, to a
    /// directory it is refused as the directory is.
    @Test func openFollowsSymlink() throws {
        let dir = try parityTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let link = dir.appendingPathComponent("budget.v1.page").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: parityFixture("darwin.v1.page"))
        let now = try fixtureObservedAt()
        let want = try BudgetPage.open(path: parityFixture("darwin.v1.page")).read(now: now).get()
        let got = try BudgetPage.open(path: link).read(now: now).get()
        #expect(got == want)

        let sub = dir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)
        let dirLink = dir.appendingPathComponent("dir.v1.page").path
        try FileManager.default.createSymbolicLink(atPath: dirLink, withDestinationPath: sub.path)
        #expect(throws: BudgetError.notFound(errno: EISDIR)) { try BudgetPage.open(path: dirLink) }
    }

    /// The open's own errno reaches the caller: ENOTDIR for a path through a
    /// regular file.
    @Test func openCarriesEnotdir() throws {
        let dir = try parityTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("budget.v1.page").path
        try FileManager.default.copyItem(atPath: parityFixture("darwin.v1.page"), toPath: file)

        #expect(throws: BudgetError.notFound(errno: ENOTDIR)) {
            try BudgetPage.open(path: file + "/budget.v1.page")
        }
    }

    /// The open's own errno reaches the caller: EACCES for a file it may not
    /// read. Root reads anything, so the test is reported as skipped there.
    @Test(.enabled(if: geteuid() != 0, "needs a non-root user"))
    func openCarriesEacces() throws {
        let dir = try parityTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("budget.v1.page").path
        try FileManager.default.copyItem(atPath: parityFixture("darwin.v1.page"), toPath: file)

        try #require(chmod(file, 0) == 0, "chmod errno \(errno)")
        defer { _ = chmod(file, 0o600) }
        #expect(throws: BudgetError.notFound(errno: EACCES)) { try BudgetPage.open(path: file) }
    }
}
