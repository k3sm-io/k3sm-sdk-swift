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

import CK3smTestWake
import Darwin
import Foundation
@testable import K3smSDK
import Synchronization
import Testing

let fixtureDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Fixtures/page")

/// A page file the test owns, with a writable shared mapping of it standing
/// in for the writer, and an optional doorbell file beside it.
final class WritablePage: @unchecked Sendable {
    let dir: String
    let path: String
    let base: UnsafeMutableRawPointer
    private let fd: Int32

    init(
        fresh: Bool = true, fixture: String = "darwin.v1.page",
        in parent: URL = FileManager.default.temporaryDirectory
    ) throws {
        let made = parent.appendingPathComponent("k3sm-sdk-notifier-\(UUID().uuidString)").path
        dir = made
        try FileManager.default.createDirectory(atPath: made, withIntermediateDirectories: true)
        // A class init that throws before every stored property is set never
        // runs deinit, so a failure here removes the directory itself.
        var ok = false
        defer { if !ok { try? FileManager.default.removeItem(atPath: made) } }
        path = dir + "/budget.v1.page"
        try FileManager.default.copyItem(
            atPath: fixtureDir.appendingPathComponent(fixture).path, toPath: path)
        fd = open(path, O_RDWR)
        guard fd >= 0, let m = mmap(nil, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0), m != MAP_FAILED else {
            if fd >= 0 { close(fd) }
            throw POSIXError(.EIO)
        }
        base = m
        ok = true
        if fresh { store(PageLayout.observedAt, UInt64(bitPattern: Int64(Date().timeIntervalSince1970))) }
    }

    deinit {
        munmap(base, 4096)
        close(fd)
        try? FileManager.default.removeItem(atPath: dir)
    }

    var doorbellPath: String { dir + "/budget.bell" }

    func word(_ offset: Int) -> UnsafeMutablePointer<Atomic<UInt64>> {
        (base + offset).assumingMemoryBound(to: Atomic<UInt64>.self)
    }

    func store(_ offset: Int, _ value: UInt64) { word(offset).pointee.store(value, ordering: .releasing) }
    func load(_ offset: Int) -> UInt64 { word(offset).pointee.load(ordering: .acquiring) }

    /// A seqlock publish of a fresh sample, optionally with a new level.
    func publish(level: UInt64? = nil) {
        let seq = load(PageLayout.seq)
        store(PageLayout.seq, seq &+ 1)
        store(PageLayout.observedAt, UInt64(bitPattern: Int64(Date().timeIntervalSince1970)))
        if let level { store(PageLayout.level, level) }
        store(PageLayout.seq, seq &+ 2)
    }

    func bumpEpoch() { store(PageLayout.notifyEpoch, load(PageLayout.notifyEpoch) &+ 1) }

    func wake() {
        let rc = ck3sm_test_wake_all(base + PageLayout.notifyEpoch)
        precondition(rc == 0 || rc == ENOENT, "wake: errno \(rc)")
    }

    func ringDoorbell() throws {
        let bell = open(doorbellPath, O_WRONLY)
        guard bell >= 0 else { throw POSIXError(.EIO) }
        defer { close(bell) }
        var b: UInt8 = 1
        guard pwrite(bell, &b, 1, 0) == 1 else { throw POSIXError(.EIO) }
    }
}

/// An `AsyncStream` iterator whose `next` is bounded: a yield that never
/// comes records an issue after `seconds` instead of hanging the test.
final class BoundedIterator<Element: Sendable>: @unchecked Sendable {
    private var it: AsyncStream<Element>.Iterator

    init(_ stream: AsyncStream<Element>) { it = stream.makeAsyncIterator() }

    /// The next element, or nil when the stream ended; a timeout records an
    /// issue and returns nil, so it fails the test either way.
    func next(within seconds: Double = 5, sourceLocation: SourceLocation = #_sourceLocation) async -> Element? {
        let got: Element?? = await withTaskGroup(of: Element??.self) { group in
            group.addTask {
                var it = self.it
                let e = await it.next()
                self.it = it
                return .some(e)
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return .none
            }
            let first = await group.next() ?? .none
            group.cancelAll()
            return first
        }
        guard let got else {
            Issue.record("no element within \(seconds) s", sourceLocation: sourceLocation)
            return nil
        }
        return got
    }
}

/// The reads a `changes()` consumer collected.
final class Reads: Sendable {
    let value = Mutex<[Result<BudgetSnapshot, BudgetError>]>([])
}
