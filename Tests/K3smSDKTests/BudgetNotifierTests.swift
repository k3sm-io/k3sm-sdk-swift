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

/// An `AsyncStream` iterator whose `next` is bounded: a yield that never
/// comes records an issue after `seconds` instead of hanging the test.
private final class BoundedIterator<Element: Sendable>: @unchecked Sendable {
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

    /// A bump between reading a snapshot and creating the notifier is
    /// taken as seen at `init`; seeding with the snapshot's epoch reports it.
    @Test func seedFromSnapshotReportsInterveningChange() throws {
        let w = try WritablePage()
        w.publish()
        let page = try BudgetPage.open(path: w.path)
        let snapshot = try page.read().get()
        w.bumpEpoch()

        let unseeded = try BudgetNotifier(page)
        #expect(unseeded.poll() == nil)

        let n = try BudgetNotifier(page)
        n.seed(snapshot.notifyEpoch)
        #expect(n.notifyEpoch == snapshot.notifyEpoch)
        #expect(n.poll() == snapshot.notifyEpoch &+ 1)
        #expect(n.poll() == nil)

        let live = try BudgetNotifier(page)
        live.seed(page.loadNotifyEpoch())
        #expect(live.poll() == nil)

        let waiter = try BudgetNotifier(page)
        waiter.seed(snapshot.notifyEpoch)
        #expect(waiter.wait(timeout: .milliseconds(200)) == snapshot.notifyEpoch &+ 1)
        #expect(waiter.wait(timeout: .zero) == nil)
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

    /// A doorbell path that is a FIFO with no writer, or a directory, is
    /// refused at once instead of blocking the init or being watched.
    @Test func doorbellFifoWithNoWriterThrowsInsteadOfBlocking() throws {
        let w = try WritablePage()
        let page = try BudgetPage.open(path: w.path)

        let dirBell = w.dir + "/bell.d"
        try FileManager.default.createDirectory(atPath: dirBell, withIntermediateDirectories: false)
        #expect(throws: BudgetError.notFound(errno: EISDIR)) {
            try BudgetNotifier(page, doorbellPath: dirBell)
        }

        // The init runs on its own thread; if it has not returned within the
        // bound, the test opens the FIFO for writing to release it and fails.
        let fifo = w.dir + "/fifo.bell"
        try #require(mkfifo(fifo, 0o600) == 0, "mkfifo errno \(errno)")
        let result = Mutex<Result<Void, BudgetError>?>(nil)
        let done = DispatchSemaphore(value: 0)
        let opener = Thread {
            let r = Result { () throws(BudgetError) in
                _ = try BudgetNotifier(page, doorbellPath: fifo)
            }
            result.withLock { $0 = r }
            done.signal()
        }
        opener.start()
        if done.wait(timeout: .now() + 3) == .timedOut {
            Issue.record("BudgetNotifier init blocked on a FIFO doorbell")
            let wfd = Darwin.open(fifo, O_RDWR | O_NONBLOCK | O_CLOEXEC)
            _ = done.wait(timeout: .now() + 3)
            if wfd >= 0 { _ = close(wfd) }
            return
        }
        let r = try #require(result.withLock { $0 })
        #expect(throws: BudgetError.notFound(errno: EINVAL)) { try r.get() }
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
        let it = BoundedIterator(levels)
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
        let it = BoundedIterator(n.changes())
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

    /// After a stale yield, a brief torn read whose one-period re-read is
    /// stale again is not yielded as a second stale, and a fresh page that
    /// follows is.
    @Test func changesDoesNotRepeatAStaleYieldAfterATransientTornRead() async throws {
        let w = try WritablePage(fresh: false)
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

        var deadline = ContinuousClock.now + .seconds(5)
        while reads().isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard let first = reads().first, isStale(first) else {
            Issue.record("want a stale first read, got \(reads())")
            return
        }

        // A write that starts and is abandoned, leaving the page stale: torn
        // for 400 ms, well inside the one-second re-read, with no epoch bump.
        let seq = w.load(PageLayout.seq)
        w.store(PageLayout.seq, seq &+ 1)
        try await Task.sleep(for: .milliseconds(400))
        w.store(PageLayout.seq, seq)
        // The re-read lands about one period after the torn read was seen.
        try await Task.sleep(for: .milliseconds(1400))
        let after = reads()
        #expect(after.count == 1, "the stale error was yielded again, or the torn one was: \(after)")

        // A fresh sample, still with no epoch bump, is yielded.
        w.publish()
        deadline = ContinuousClock.now + .seconds(3)
        while reads().count < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let all = reads()
        guard all.count == 2, case .success = all[1] else {
            Issue.record("want one fresh read after the stale one, got \(all)")
            return
        }
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

    /// A seed ahead of the live word is still a difference: `poll()` reports
    /// the live epoch once and then nothing.
    @Test func seedAheadOfLiveWordReportsOnce() throws {
        let w = try WritablePage()
        let page = try BudgetPage.open(path: w.path)
        let live = page.loadNotifyEpoch()
        let n = try BudgetNotifier(page)
        n.seed(live &+ 5)
        #expect(n.poll() == live)
        #expect(n.poll() == nil)
    }

    /// A seed behind the live word (the live epoch minus one, wrapping) is a
    /// difference too: `poll()` reports the live epoch once and then nothing.
    /// This pins the behind-by-one case; it does not by itself tell `!=` from
    /// `>`, since a greater-than comparison also reports here.
    @Test func seedBehindLiveWordReportsOnce() throws {
        let w = try WritablePage()
        let page = try BudgetPage.open(path: w.path)
        let live = page.loadNotifyEpoch()
        let n = try BudgetNotifier(page)
        n.seed(live &- 1)
        #expect(n.poll() == live)
        #expect(n.poll() == nil)
    }

    /// The seeds are at the edges of the range; the live word is not (the test
    /// helpers cannot set it to the top of the range). Each seed reports the
    /// live epoch once, then nothing, without trapping. The ahead-of-live seeds
    /// (`UInt64.max`, and `live + 1`) are the cases that fail under a
    /// greater-than comparison.
    @Test func seedAtRangeEdgesReportsOnceWithoutTrapping() throws {
        let w = try WritablePage()
        let page = try BudgetPage.open(path: w.path)
        let live = page.loadNotifyEpoch()
        var exercised = 0
        for seed in [UInt64.max, 0, live &+ 1, live &- UInt64.max] where seed != live {
            exercised += 1
            let n = try BudgetNotifier(page)
            n.seed(seed)
            #expect(n.poll() == live)
            #expect(n.poll() == nil)
        }
        #expect(exercised >= 3)
    }
}
