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

/// The process-spawning tests run only in the integration stage
/// (hack/ci.sh --notifier), which sets this variable; the unit stage and the
/// sanitizer runs skip them.
private let integration = ProcessInfo.processInfo.environment["K3SM_SDK_INTEGRATION"] == "1"

private let fixtureDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Fixtures/page")

/// A page file the test owns, with a writable shared mapping of it standing
/// in for the writer, and an optional doorbell file beside it.
private final class WritablePage: @unchecked Sendable {
    let dir: String
    let path: String
    let base: UnsafeMutableRawPointer
    private let fd: Int32

    init(fresh: Bool = true) throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("k3sm-sdk-notifier-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        path = dir + "/budget.v1.page"
        try FileManager.default.copyItem(
            atPath: fixtureDir.appendingPathComponent("darwin.v1.page").path, toPath: path)
        fd = open(path, O_RDWR)
        guard fd >= 0, let m = mmap(nil, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0), m != MAP_FAILED else {
            throw POSIXError(.EIO)
        }
        base = m
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

/// Runs `body` on a dedicated thread, as the notifier's documentation asks
/// of a blocking wait. `ready` is signalled just before `body` starts.
private final class Waiter<T: Sendable>: @unchecked Sendable {
    let ready = DispatchSemaphore(value: 0)
    private let done = DispatchSemaphore(value: 0)
    private var value: T?

    init(_ body: @escaping @Sendable () -> T) {
        let t = Thread { [self] in
            ready.signal()
            value = body()
            done.signal()
        }
        t.start()
    }

    /// The body's result, or nil when it is still running after `seconds`.
    func result(within seconds: Double) -> T? {
        done.wait(timeout: .now() + seconds) == .success ? value : nil
    }
}

/// The reads a `changes()` consumer collected.
private final class Reads: Sendable {
    let value = Mutex<[Result<BudgetSnapshot, BudgetError>]>([])
}

private func elapsed(_ body: () -> Void) -> Duration {
    ContinuousClock().measure(body)
}

/// The stand-in writer process: the PageTestWriter executable, built beside
/// the test bundle, driven one command line at a time.
private final class WriterProcess {
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()

    init(page: String) throws {
        // The test bundle is <build>/K3smSDKPackageTests.xctest/Contents/MacOS/<binary>.
        var info = Dl_info()
        guard dladdr(#dsohandle, &info) != 0, let image = info.dli_fname else { throw POSIXError(.ENOENT) }
        var build = URL(fileURLWithPath: String(cString: image))
        while build.pathExtension != "xctest", build.path != "/" { build.deleteLastPathComponent() }
        build.deleteLastPathComponent()
        process.executableURL = build.appendingPathComponent("PageTestWriter")
        process.arguments = [page]
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()
    }

    deinit {
        if process.isRunning { process.terminate() }
    }

    /// Sends one command and returns the writer's (seq, notifyEpoch) after it.
    func send(_ command: String) throws -> (seq: UInt64, epoch: UInt64) {
        try stdin.fileHandleForWriting.write(contentsOf: Data((command + "\n").utf8))
        var line: [UInt8] = []
        while true {
            guard let b = try stdout.fileHandleForReading.read(upToCount: 1), let c = b.first else {
                throw POSIXError(.EPIPE)
            }
            if c == UInt8(ascii: "\n") { break }
            line.append(c)
        }
        let parts = String(decoding: line, as: UTF8.self).split(separator: " ")
        guard parts.count == 3, parts[0] == "ok", let seq = UInt64(parts[1]), let epoch = UInt64(parts[2]) else {
            throw POSIXError(.EPROTO)
        }
        return (seq, epoch)
    }

    func quit() {
        try? stdin.fileHandleForWriting.write(contentsOf: Data("quit\n".utf8))
        process.waitUntilExit()
    }
}

/// Serialized: changesYieldsSnapshotsAndEndsOnCancel counts the live
/// `changes()` threads process-wide, so another test's feeder running beside
/// it would read as a thread that never ended.
@Suite(.serialized) struct BudgetNotifierTests {
    @Test func pollReportsOnlyNotifyEpochChanges() throws {
        let w = try WritablePage()
        let n = try BudgetNotifier(try BudgetPage.open(path: w.path))
        #expect(n.poll() == nil)
        w.publish()
        #expect(n.poll() == nil)
        w.bumpEpoch()
        #expect(n.poll() == 1)
        #expect(n.poll() == nil)
        #expect(n.notifyEpoch == 1)
    }

    @Test func waitTimesOutWithoutAChange() throws {
        let w = try WritablePage()
        let n = try BudgetNotifier(try BudgetPage.open(path: w.path))
        var got: UInt64? = 7
        let d = elapsed { got = n.wait(timeout: .milliseconds(80)) }
        #expect(got == nil)
        #expect(d >= .milliseconds(80))
        #expect(n.wait(timeout: .zero) == nil)
    }

    @Test func waitReturnsAtOnceForAnUnseenChange() throws {
        let w = try WritablePage()
        let n = try BudgetNotifier(try BudgetPage.open(path: w.path))
        w.bumpEpoch()
        w.bumpEpoch()
        var got: UInt64?
        let d = elapsed { got = n.wait(timeout: .seconds(10)) }
        #expect(got == 2)
        #expect(d < .seconds(1))
    }

    @Test func waitWakesOnAnEpochBumpInProcess() throws {
        let w = try WritablePage()
        let n = try BudgetNotifier(try BudgetPage.open(path: w.path))
        let waiter = Waiter { n.wait(timeout: .seconds(10)) }
        waiter.ready.wait()
        usleep(20_000)
        w.publish(level: 3)
        w.bumpEpoch()
        w.wake()
        #expect(waiter.result(within: 5) == .some(1))
    }

    /// With a doorbell, a change is seen through the kqueue doorbell even
    /// when the writer never wakes the word.
    @Test func doorbellWakesWithoutAnAddressWake() throws {
        let w = try WritablePage()
        #expect(FileManager.default.createFile(atPath: w.doorbellPath, contents: Data([0])))
        let n = try BudgetNotifier(try BudgetPage.open(path: w.path), doorbellPath: w.doorbellPath)
        let waiter = Waiter { n.wait(timeout: .seconds(10)) }
        waiter.ready.wait()
        usleep(20_000)
        w.bumpEpoch()
        try w.ringDoorbell()
        #expect(waiter.result(within: 5) == .some(1))
    }

    /// With a doorbell, a bump whose doorbell write never happened (and
    /// with no address wake either) is still seen, from the epoch word,
    /// well before the timeout.
    @Test func waitWakesOnEpochBumpWhenDoorbellNeverRings() throws {
        let w = try WritablePage()
        #expect(FileManager.default.createFile(atPath: w.doorbellPath, contents: Data([0])))
        let n = try BudgetNotifier(try BudgetPage.open(path: w.path), doorbellPath: w.doorbellPath)
        let waiter = Waiter { n.wait(timeout: .seconds(4)) }
        waiter.ready.wait()
        usleep(20_000)
        w.bumpEpoch()
        #expect(waiter.result(within: 1.5) == .some(1))
    }

    @Test func missingDoorbellIsNotFound() throws {
        let w = try WritablePage()
        let page = try BudgetPage.open(path: w.path)
        #expect(throws: BudgetError.notFound(errno: ENOENT)) {
            try BudgetNotifier(page, doorbellPath: w.dir + "/absent.bell")
        }
    }

    /// changes() yields the current snapshot, then one per change, and its
    /// thread ends when the consumer cancels.
    @Test func changesYieldsSnapshotsAndEndsOnCancel() async throws {
        let w = try WritablePage()
        let n = try BudgetNotifier(try BudgetPage.open(path: w.path))
        let before = BudgetNotifier.liveFeeders.load(ordering: .relaxed)
        let (levels, feed) = AsyncStream.makeStream(of: NodeBudget.Level.self)
        let task = Task {
            for await r in n.changes() {
                if case let .success(s) = r { feed.yield(s.level) }
            }
            feed.finish()
        }
        var it = levels.makeAsyncIterator()
        let first = await it.next()
        #expect(first == .ok)
        w.publish()
        w.wake() // a seq-only sample: nothing is yielded for it
        w.publish(level: 3)
        w.bumpEpoch()
        w.wake()
        #expect(await it.next() == .critical)
        task.cancel()
        #expect(await it.next() == nil)
        // The feeder thread notices the cancellation within one wait slice.
        let deadline = ContinuousClock.now + .seconds(5)
        while BudgetNotifier.liveFeeders.load(ordering: .relaxed) > before, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(BudgetNotifier.liveFeeders.load(ordering: .relaxed) <= before)
    }

    /// A read that is stale is yielded as the error after one re-read a
    /// writer period later.
    @Test func changesYieldsStaleAfterOneReRead() async throws {
        let w = try WritablePage(fresh: false)
        let n = try BudgetNotifier(try BudgetPage.open(path: w.path))
        let start = ContinuousClock.now
        var it = n.changes().makeAsyncIterator()
        let first = await it.next()
        #expect(ContinuousClock.now - start >= .seconds(1))
        guard case .failure(.stale) = first else {
            Issue.record("want stale, got \(String(describing: first))")
            return
        }
    }

    /// A writer that goes silent with no epoch bump still turns into a
    /// yielded `stale` once the page's own staleness rule (three writer
    /// periods since observedAt) says so.
    @Test func changesYieldsStaleWhenWriterGoesSilent() async throws {
        let w = try WritablePage()
        // One second old with a one-second period: fresh now, even after a
        // slow first read on a loaded machine, stale within about three
        // seconds, then one re-read a period later.
        w.store(PageLayout.writerPeriodSeconds, 1)
        w.store(PageLayout.observedAt, UInt64(bitPattern: Int64(Date().timeIntervalSince1970) - 1))
        let n = try BudgetNotifier(try BudgetPage.open(path: w.path))
        let seen = Reads()
        let task = Task {
            for await r in n.changes() { seen.value.withLock { $0.append(r) } }
        }
        defer { task.cancel() }
        let deadline = ContinuousClock.now + .seconds(6)
        func gotStale() -> Bool {
            seen.value.withLock { $0.contains { if case .failure(.stale) = $0 { true } else { false } } }
        }
        while !gotStale(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let all = seen.value.withLock { $0 }
        guard case .success = all.first else {
            Issue.record("want a fresh first read, got \(String(describing: all.first))")
            return
        }
        #expect(gotStale(), "no stale read yielded after the writer went silent: \(all)")
    }

    /// A writer that keeps refreshing observedAt with no epoch bump is alive:
    /// nothing is yielded past the stale window. When it then goes silent the
    /// stale error is yielded, and when it resumes the fresh read is.
    @Test func changesStaysQuietForALiveWriterWithAnUnchangedEpoch() async throws {
        let w = try WritablePage()
        w.store(PageLayout.writerPeriodSeconds, 1)
        let n = try BudgetNotifier(try BudgetPage.open(path: w.path))
        let seen = Reads()
        let task = Task {
            for await r in n.changes() { seen.value.withLock { $0.append(r) } }
        }
        defer { task.cancel() }
        func reads() -> [Result<BudgetSnapshot, BudgetError>] { seen.value.withLock { $0 } }
        func isStale(_ r: Result<BudgetSnapshot, BudgetError>) -> Bool {
            if case .failure(.stale) = r { true } else { false }
        }

        // Alive: refreshed every 200 ms for longer than the three-second
        // stale window.
        let alive = ContinuousClock.now + .milliseconds(4500)
        while ContinuousClock.now < alive {
            w.publish()
            try await Task.sleep(for: .milliseconds(200))
        }
        let quiet = reads()
        #expect(quiet.count == 1, "a live writer produced yields: \(quiet)")
        guard case .success = quiet.first else {
            Issue.record("want a fresh first read, got \(String(describing: quiet.first))")
            return
        }

        // Silent: the stale error arrives.
        var deadline = ContinuousClock.now + .seconds(8)
        while !reads().contains(where: isStale), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(reads().contains(where: isStale), "no stale read after the writer went silent: \(reads())")

        // Resumed, still with no epoch bump: a fresh read follows the stale one.
        w.publish()
        func recovered() -> Bool {
            let all = reads()
            guard let i = all.lastIndex(where: isStale) else { return false }
            return all[(i + 1)...].contains { if case .success = $0 { true } else { false } }
        }
        deadline = ContinuousClock.now + .seconds(3)
        while !recovered(), ContinuousClock.now < deadline {
            w.publish()
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(recovered(), "no fresh read after the writer resumed: \(reads())")
    }

    /// After a torn yield, a writer that recovers with no epoch bump is
    /// yielded, and when it then goes silent the stale error is.
    @Test func changesRecoversFromATornReadAndThenReportsStale() async throws {
        let w = try WritablePage()
        w.store(PageLayout.writerPeriodSeconds, 1)
        w.store(PageLayout.seq, 1) // a write that never finishes: every read is torn
        let n = try BudgetNotifier(try BudgetPage.open(path: w.path))
        let seen = Reads()
        let task = Task {
            for await r in n.changes() { seen.value.withLock { $0.append(r) } }
        }
        defer { task.cancel() }
        func reads() -> [Result<BudgetSnapshot, BudgetError>] { seen.value.withLock { $0 } }
        func wait(for want: (Result<BudgetSnapshot, BudgetError>) -> Bool, seconds: Int64) async throws -> Bool {
            let deadline = ContinuousClock.now + .seconds(seconds)
            while !reads().contains(where: want), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            return reads().contains(where: want)
        }

        let torn = try await wait(for: { if case .failure(.torn) = $0 { true } else { false } }, seconds: 5)
        #expect(torn, "want a torn read, got \(reads())")
        // The write finishes, with no epoch bump.
        w.store(PageLayout.observedAt, UInt64(bitPattern: Int64(Date().timeIntervalSince1970)))
        w.store(PageLayout.seq, 2)
        let fresh = try await wait(for: { if case .success = $0 { true } else { false } }, seconds: 3)
        #expect(fresh, "no fresh read after the torn write finished: \(reads())")
        // The writer then goes silent.
        let stale = try await wait(for: { if case .failure(.stale) = $0 { true } else { false } }, seconds: 8)
        #expect(stale, "no stale read after the writer went silent: \(reads())")
    }

    /// A timeout too large to add to the clock waits with no deadline rather
    /// than returning at once.
    @Test func waitWithAMaximalTimeoutDoesNotReturnAtOnce() throws {
        let w = try WritablePage()
        let n = try BudgetNotifier(try BudgetPage.open(path: w.path))
        let waiter = Waiter { n.wait(timeout: .seconds(Int64.max)) }
        waiter.ready.wait()
        usleep(50_000)
        let early = waiter.result(within: 0)
        #expect(early == nil, "returned at once: \(String(describing: early))")
        w.bumpEpoch()
        w.wake()
        // A lost wake fails here within a few seconds instead of hanging.
        #expect(waiter.result(within: 3) == .some(1))
    }

    /// The gate: a reader in this process wakes on a notifyEpoch bump made by
    /// a writer in another, and does not report a seq-only change even when
    /// that writer wakes it. The notifyEpoch value is the oracle: every epoch
    /// the reader observes is one the writer published, and an epoch it skips
    /// is accounted for as a recorded coalesce.
    @Test(.enabled(if: integration, "integration stage only (hack/ci.sh --notifier)"))
    func crossProcessWakeOnNotifyEpochOnly() throws {
        let w = try WritablePage()
        let n = try BudgetNotifier(try BudgetPage.open(path: w.path))

        // The writer process starts only after the waiter is ready.
        let first = Waiter { n.wait(timeout: .seconds(10)) }
        first.ready.wait()
        let writer = try WriterProcess(page: w.path)
        defer { writer.quit() }
        let p0 = try writer.send("epoch")
        #expect(first.result(within: 5) == .some(p0.epoch))

        var published: [UInt64] = [p0.epoch]
        var observed: [UInt64] = [p0.epoch]
        var coalesced: [UInt64] = []
        for round in 0..<10 {
            // A seq-only sample, with a wake: the reader must time out.
            let quiet = Waiter { n.wait(timeout: .milliseconds(400)) }
            quiet.ready.wait()
            let before = w.load(PageLayout.seq)
            let ps = try writer.send("seq")
            #expect(ps.seq > before, "round \(round): the writer's sample did not advance seq")
            #expect(ps.epoch == published.last)
            let none = quiet.result(within: 5)
            #expect(none == .some(nil), "round \(round): a seq-only change was reported")

            // A level change: the reader wakes with the writer's epoch.
            let loud = Waiter { n.wait(timeout: .seconds(10)) }
            loud.ready.wait()
            let pe = try writer.send("epoch")
            published.append(pe.epoch)
            let got = loud.result(within: 5)
            #expect(got == .some(pe.epoch), "round \(round): want epoch \(pe.epoch), got \(String(describing: got))")
            if case let .some(.some(e)) = got { observed.append(e) }
        }

        // Three bumps before the reader looks: it sees the last one, and the
        // two in between are a recorded coalesce, not a silent skip.
        let a = try writer.send("quiet")
        let b = try writer.send("quiet")
        let c = try writer.send("epoch")
        published += [a.epoch, b.epoch, c.epoch]
        let late = n.wait(timeout: .seconds(10))
        #expect(late == c.epoch)
        if let late {
            observed.append(late)
            coalesced += [a.epoch, b.epoch]
        }

        #expect(Set(observed).isSubset(of: Set(published)))
        #expect(Set(observed).union(coalesced) == Set(published))
        #expect(observed == observed.sorted())
    }
}
