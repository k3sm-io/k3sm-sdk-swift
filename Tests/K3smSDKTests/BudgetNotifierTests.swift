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

private func elapsed(_ body: () -> Void) -> Duration {
    ContinuousClock().measure(body)
}

/// The PageTestWriter executable, built beside the test bundle, which is
/// <build>/K3smSDKPackageTests.xctest/Contents/MacOS/<binary>.
func pageTestWriterURL() throws -> URL {
    var info = Dl_info()
    guard dladdr(#dsohandle, &info) != 0, let image = info.dli_fname else { throw POSIXError(.ENOENT) }
    var build = URL(fileURLWithPath: String(cString: image))
    while build.pathExtension != "xctest", build.path != "/" { build.deleteLastPathComponent() }
    build.deleteLastPathComponent()
    return build.appendingPathComponent("PageTestWriter")
}

/// The stand-in writer process: the PageTestWriter executable, built beside
/// the test bundle, driven one command line at a time.
private final class WriterProcess {
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()

    init(page: String) throws {
        process.executableURL = try pageTestWriterURL()
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
    @Test func writablePageInitFailureLeavesNothingBehind() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("k3sm-sdk-initfail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        #expect(throws: (any Error).self) {
            _ = try WritablePage(fixture: "no-such-fixture.page", in: parent)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
    }

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

    /// A failed doorbell open closes its descriptor: a doorbell path that is
    /// a directory and one that is missing, a few hundred times each, leave
    /// the process's descriptor count where it was (the counting protocol is
    /// on `openDescriptorCount`).
    @Test func failedDoorbellOpensLeakNoDescriptor() throws {
        let w = try WritablePage()
        let page = try BudgetPage.open(path: w.path)
        let dirBell = w.dir + "/bell.d"
        try FileManager.default.createDirectory(atPath: dirBell, withIntermediateDirectories: false)
        let missing = w.dir + "/missing.bell"

        let perRound = 300
        func round() {
            for _ in 0..<perRound {
                #expect(throws: BudgetError.notFound(errno: EISDIR)) {
                    try BudgetNotifier(page, doorbellPath: dirBell)
                }
                #expect(throws: BudgetError.notFound(errno: ENOENT)) {
                    try BudgetNotifier(page, doorbellPath: missing)
                }
            }
        }
        round()
        let before = openDescriptorCount()
        round()
        round()
        let after = openDescriptorCount()
        #expect(after - before < descriptorCountSlack, "descriptors grew from \(before) to \(after)")
    }

    /// A character device as the doorbell path is refused like any other
    /// non-regular file (EINVAL), and the refusals leak no descriptor.
    @Test func doorbellCharacterDeviceIsRefusedWithoutLeaking() throws {
        let w = try WritablePage()
        let page = try BudgetPage.open(path: w.path)
        let perRound = 300
        func round() {
            for _ in 0..<perRound {
                #expect(throws: BudgetError.notFound(errno: EINVAL)) {
                    try BudgetNotifier(page, doorbellPath: "/dev/null")
                }
            }
        }
        round()
        let before = openDescriptorCount()
        round()
        round()
        let after = openDescriptorCount()
        #expect(after - before < descriptorCountSlack, "descriptors grew from \(before) to \(after)")
    }

    /// A doorbell file unlinked and recreated after construction leaves the
    /// notifier watching the old inode; a bump (and a ring of the new file)
    /// is still seen through the periodic check of the epoch word.
    @Test func doorbellReplacedAfterConstructionStillSeesTheChange() throws {
        let w = try WritablePage()
        #expect(FileManager.default.createFile(atPath: w.doorbellPath, contents: Data([0])))
        let n = try BudgetNotifier(try BudgetPage.open(path: w.path), doorbellPath: w.doorbellPath)
        try #require(unlink(w.doorbellPath) == 0, "unlink errno \(errno)")
        #expect(FileManager.default.createFile(atPath: w.doorbellPath, contents: Data([0])))
        let waiter = Waiter { n.wait(timeout: .seconds(20)) }
        waiter.ready.wait()
        usleep(20_000)
        w.bumpEpoch()
        try w.ringDoorbell()
        #expect(waiter.result(within: 15) == .some(1))
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

    /// A cancel while the feeder waits one writer period before re-reading a
    /// torn page ends its thread promptly, even with an hour-long period.
    @Test func changesEndsOnCancelDuringTheReReadWait() async throws {
        let w = try WritablePage()
        w.store(PageLayout.writerPeriodSeconds, 3600)
        let n = try BudgetNotifier(try BudgetPage.open(path: w.path))
        let before = BudgetNotifier.liveFeeders.load(ordering: .relaxed)
        let seen = Reads()
        let task = Task {
            for await r in n.changes() { seen.value.withLock { $0.append(r) } }
        }
        defer { task.cancel() }
        // The first, fresh read sets the feeder's period to 3600 s.
        var deadline = ContinuousClock.now + .seconds(5)
        while seen.value.withLock({ $0.isEmpty }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard case .success = seen.value.withLock({ $0.first }) else {
            Issue.record("want a fresh first read, got \(seen.value.withLock { $0 })")
            return
        }
        // A write that never finishes, announced by an epoch bump: the read
        // is torn, so the feeder waits one period before its re-read.
        w.store(PageLayout.seq, w.load(PageLayout.seq) | 1)
        w.bumpEpoch()
        w.wake()
        try await Task.sleep(for: .milliseconds(500))
        #expect(seen.value.withLock { $0.count } == 1, "the torn read was not held for its re-read")
        task.cancel()
        let cancelled = ContinuousClock.now
        deadline = cancelled + .seconds(2)
        while BudgetNotifier.liveFeeders.load(ordering: .relaxed) > before, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(
            BudgetNotifier.liveFeeders.load(ordering: .relaxed) <= before,
            "the feeder still ran \(ContinuousClock.now - cancelled) after the cancel")
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

        // Silent: the stale error arrives. The stream yields a stale result
        // only after a one-period re-read, which a stalled run can delay well
        // past the stale window, so the wait is generous and ends as soon as
        // the stale read is seen. Without it the resume phase is skipped: a
        // publish before the stale read is recorded would hide it.
        var deadline = ContinuousClock.now + .seconds(20)
        while !reads().contains(where: isStale), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let sawStale = reads().contains(where: isStale)
        #expect(sawStale, "no stale read after the writer went silent: \(reads())")
        guard sawStale else { return }

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

        // The stream yields a failed read only after a one-period re-read,
        // so acting before the previous read is recorded would hide it.
        let torn = try await wait(for: { if case .failure(.torn) = $0 { true } else { false } }, seconds: 20)
        #expect(torn, "want a torn read, got \(reads())")
        guard torn else { return }
        // The write finishes, with no epoch bump.
        w.store(PageLayout.observedAt, UInt64(bitPattern: Int64(Date().timeIntervalSince1970)))
        w.store(PageLayout.seq, 2)
        let fresh = try await wait(for: { if case .success = $0 { true } else { false } }, seconds: 10)
        #expect(fresh, "no fresh read after the torn write finished: \(reads())")
        guard fresh else { return }
        // The writer then goes silent.
        let stale = try await wait(for: { if case .failure(.stale) = $0 { true } else { false } }, seconds: 30)
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

    /// When changes() cannot reopen the doorbell the notifier was built
    /// with, its thread waits on the epoch word instead and still yields
    /// each change.
    @Test func changesFallsBackToTheWordWhenTheDoorbellCannotBeReopened() async throws {
        let w = try WritablePage()
        #expect(FileManager.default.createFile(atPath: w.doorbellPath, contents: Data([0])))
        let n = try BudgetNotifier(try BudgetPage.open(path: w.path), doorbellPath: w.doorbellPath)
        // A directory of the same name: the reopen in changes() is refused.
        try FileManager.default.removeItem(atPath: w.doorbellPath)
        try FileManager.default.createDirectory(atPath: w.doorbellPath, withIntermediateDirectories: false)
        let (levels, feed) = AsyncStream.makeStream(of: NodeBudget.Level.self)
        let task = Task {
            for await r in n.changes() {
                if case let .success(s) = r { feed.yield(s.level) }
            }
            feed.finish()
        }
        defer { task.cancel() }
        let it = BoundedIterator(levels)
        #expect(await it.next() == .ok)
        w.publish(level: 3)
        w.bumpEpoch()
        w.wake()
        #expect(await it.next() == .critical)
    }

    /// A read that is torn, by a write that finishes inside the writer
    /// period, is not yielded: after the epoch bump that announced it, the
    /// stream yields the re-read's snapshot a period later, and never the
    /// torn error.
    @Test func changesYieldsTheHealedReReadAfterATornRead() async throws {
        let w = try WritablePage()
        w.store(PageLayout.writerPeriodSeconds, 2)
        let n = try BudgetNotifier(try BudgetPage.open(path: w.path))
        let seen = Reads()
        let task = Task {
            for await r in n.changes() { seen.value.withLock { $0.append(r) } }
        }
        defer { task.cancel() }
        func reads() -> [Result<BudgetSnapshot, BudgetError>] { seen.value.withLock { $0 } }
        func isTorn(_ r: Result<BudgetSnapshot, BudgetError>) -> Bool {
            if case .failure(.torn) = r { true } else { false }
        }

        // The first, fresh read sets the feeder's period to 2 s.
        var deadline = ContinuousClock.now + .seconds(5)
        while reads().isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard case .success = reads().first else {
            Issue.record("want a fresh first read, got \(reads())")
            return
        }

        // A write in progress, announced by an epoch bump: the read is torn.
        let seq = w.load(PageLayout.seq)
        w.store(PageLayout.seq, seq | 1)
        w.bumpEpoch()
        w.wake()
        try await Task.sleep(for: .milliseconds(500))
        #expect(reads().count == 1, "the torn read was yielded before its re-read: \(reads())")
        // The write finishes inside the period, with no further bump.
        w.store(PageLayout.observedAt, UInt64(bitPattern: Int64(Date().timeIntervalSince1970)))
        w.store(PageLayout.level, 3)
        w.store(PageLayout.seq, (seq | 1) &+ 1)

        deadline = ContinuousClock.now + .seconds(8)
        while reads().count < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let all = reads()
        guard all.count >= 2, case .success(let s) = all[1] else {
            Issue.record("want the re-read's snapshot second, got \(all)")
            return
        }
        #expect(s.level == .critical)
        #expect(!all.contains(where: isTorn), "a torn error was yielded: \(all)")
    }

    /// A consumer that drops the stream, without cancelling its task, ends
    /// the feeder thread: the stream's termination stops it.
    @Test func changesEndsWhenTheStreamIsDropped() async throws {
        let w = try WritablePage()
        let n = try BudgetNotifier(try BudgetPage.open(path: w.path))
        // A feeder an earlier test cancelled exits only at its next 100 ms
        // check: take the baseline once the count has held one value for
        // about 300 ms.
        let settle = ContinuousClock.now + .seconds(5)
        var before = BudgetNotifier.liveFeeders.load(ordering: .relaxed)
        var heldSince = ContinuousClock.now
        while ContinuousClock.now - heldSince < .milliseconds(300), ContinuousClock.now < settle {
            try await Task.sleep(for: .milliseconds(20))
            let now = BudgetNotifier.liveFeeders.load(ordering: .relaxed)
            if now != before {
                before = now
                heldSince = ContinuousClock.now
            }
        }
        let started = try await holdAndDropAStream(n, above: before)
        #expect(started, "no feeder thread started within 5 s")
        // No epoch bump follows, so only the termination can end the thread.
        let deadline = ContinuousClock.now + .seconds(10)
        while BudgetNotifier.liveFeeders.load(ordering: .relaxed) > before, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(
            BudgetNotifier.liveFeeders.load(ordering: .relaxed) <= before,
            "the feeder still ran after its stream was dropped")
    }

    /// Makes a `changes()` stream that lives only in this call, waits until
    /// its feeder runs (the live count above `baseline`) and returns
    /// whether it did; the stream is dropped on return, never cancelled.
    @inline(never)
    private func holdAndDropAStream(_ n: BudgetNotifier, above baseline: Int) async throws -> Bool {
        let stream = n.changes()
        let deadline = ContinuousClock.now + .seconds(5)
        while BudgetNotifier.liveFeeders.load(ordering: .relaxed) <= baseline, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let started = BudgetNotifier.liveFeeders.load(ordering: .relaxed) > baseline
        withExtendedLifetime(stream) {}
        return started
    }

    /// A feeder built with a doorbell that opens yields the first read and
    /// each change the writer announces by ringing it, with no address wake.
    /// Whether the ring or the 100 ms word check woke it is not told apart.
    @Test func changesWithAGoodDoorbellYieldsTheFirstReadAndTheChange() async throws {
        let w = try WritablePage()
        #expect(FileManager.default.createFile(atPath: w.doorbellPath, contents: Data([0])))
        let n = try BudgetNotifier(try BudgetPage.open(path: w.path), doorbellPath: w.doorbellPath)
        let (levels, feed) = AsyncStream.makeStream(of: NodeBudget.Level.self)
        let task = Task {
            for await r in n.changes() {
                if case let .success(s) = r { feed.yield(s.level) }
            }
            feed.finish()
        }
        defer { task.cancel() }
        let it = BoundedIterator(levels)
        #expect(await it.next() == .ok)
        w.publish(level: 3)
        w.bumpEpoch()
        try w.ringDoorbell()
        #expect(await it.next() == .critical)
    }

    /// changes() keeps its own epoch, starting from the live word: a seed
    /// that differs from the live word yields nothing extra on the stream,
    /// and the stream does not consume the notifier's seeded difference.
    @Test func changesIgnoresTheSeed() async throws {
        let w = try WritablePage()
        let page = try BudgetPage.open(path: w.path)
        let live = page.loadNotifyEpoch()
        let n = try BudgetNotifier(page)
        n.seed(live &+ 5)
        let seen = Reads()
        let task = Task {
            for await r in n.changes() { seen.value.withLock { $0.append(r) } }
        }
        defer { task.cancel() }
        func reads() -> [Result<BudgetSnapshot, BudgetError>] { seen.value.withLock { $0 } }
        func waitFor(count: Int) async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while reads().count < count, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
        }

        try await waitFor(count: 1)
        guard case .success(let s0) = reads().first else {
            Issue.record("want a fresh first read, got \(reads())")
            return
        }
        #expect(s0.level == .ok)
        // A stream that took the seed as its epoch would see a change at once.
        try await Task.sleep(for: .milliseconds(350))
        #expect(reads().count == 1, "the seed produced a yield: \(reads())")

        w.publish(level: 3)
        w.bumpEpoch()
        w.wake()
        try await waitFor(count: 2)
        let all = reads()
        guard all.count == 2, case .success(let s1) = all[1] else {
            Issue.record("want one change after the first read, got \(all)")
            return
        }
        #expect(s1.level == .critical)
        #expect(n.poll() == page.loadNotifyEpoch(), "the stream consumed the seeded difference")
        #expect(n.poll() == nil)
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

    /// A doorbell whose kevent wait fails is marked broken and the wait falls
    /// back to polling the epoch word: it neither returns early nor spins,
    /// and a later bump is still seen.
    @Test func doorbellWaitFailureFallsBackToPolling() throws {
        let w = try WritablePage()
        #expect(FileManager.default.createFile(atPath: w.doorbellPath, contents: Data([0])))
        let n = try BudgetNotifier(try BudgetPage.open(path: w.path), doorbellPath: w.doorbellPath)
        let doorbell = try #require(n.doorbell)
        doorbell.breakQueueForTesting()
        var got: UInt64? = 7
        let cpuBefore = threadCPUNanoseconds()
        let d = elapsed { got = n.wait(timeout: .milliseconds(350)) }
        let cpu = threadCPUNanoseconds() - cpuBefore
        print("doorbell fallback wait CPU ms: \(cpu / 1_000_000)")
        #expect(got == nil)
        #expect(d >= .milliseconds(340))
        #expect(d < .seconds(2))
        #expect(cpu < 100_000_000, "the wait spun: \(cpu / 1_000_000) ms of CPU in a 350 ms wait")
        #expect(doorbell.isBroken)
        let waiter = Waiter { n.wait(timeout: .seconds(4)) }
        waiter.ready.wait()
        usleep(20_000)
        w.bumpEpoch()
        w.wake()
        #expect(waiter.result(within: 1.5) == .some(1))
    }

    /// A write to the doorbell file ends the doorbell's own kevent wait long
    /// before its ceiling, with no page word anywhere in the picture. The
    /// wait returns true for both an event and a timeout, so the wake is
    /// told apart by time: it returns after the write and well before the
    /// five-second ceiling, which only the kqueue registration can do.
    @Test func doorbellWaitWakesOnAWriteLongBeforeItsCeiling() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("k3sm-sdk-bell-wake-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/budget.bell"
        #expect(FileManager.default.createFile(atPath: path, contents: Data([0])))
        let bell = try Doorbell(path: path)

        let ringAt = RingTime()
        let ringer = Thread {
            usleep(200_000)
            let fd = open(path, O_WRONLY)
            guard fd >= 0 else {
                ringAt.failed.store(true, ordering: .releasing)
                return
            }
            defer { close(fd) }
            var b: UInt8 = 1
            ringAt.at.store(clock_gettime_nsec_np(CLOCK_UPTIME_RAW), ordering: .releasing)
            if pwrite(fd, &b, 1, 0) != 1 {
                ringAt.failed.store(true, ordering: .releasing)
            }
        }
        let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        ringer.start()
        let ok = bell.wait(nanoseconds: 5_000_000_000)
        let end = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let rang = ringAt.at.load(ordering: .acquiring)
        while !ringer.isFinished { usleep(1_000) }

        let ringFailed = ringAt.failed.load(ordering: .acquiring)
        #expect(!ringFailed, "the helper could not write the doorbell")
        #expect(ok)
        #expect(rang != 0, "the wait returned before the doorbell was written")
        #expect(rang <= end)
        // The wake is measured from the write, so a helper thread that was slow
        // to start cannot fail it; a missed wake ends near the 5000 ms ceiling.
        if rang != 0, rang <= end {
            #expect(end - rang < 1_000_000_000, "the wait ended \((end - rang) / 1_000_000) ms after the write")
        }
        #expect(end - start < 3_000_000_000, "the wait ran \((end - start) / 1_000_000) ms of its 5000 ms ceiling")
    }

    /// The control: with no write, the doorbell wait runs to its ceiling and
    /// reports the timeout as true, as an event would be.
    @Test func doorbellWaitWithoutAWriteRunsToItsCeiling() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("k3sm-sdk-bell-quiet-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/budget.bell"
        #expect(FileManager.default.createFile(atPath: path, contents: Data([0])))
        let bell = try Doorbell(path: path)

        var ok = false
        let d = elapsed { ok = bell.wait(nanoseconds: 300_000_000) }
        #expect(ok)
        #expect(d >= .milliseconds(290))
        #expect(d < .seconds(2))
    }

    /// A kevent wait interrupted by a handled signal returns EINTR, and the
    /// doorbell treats that as a wake to retry, not as a failure: the wait
    /// returns true soon after the signal, long before its ceiling, and the
    /// doorbell is not marked broken. The handler is installed without
    /// SA_RESTART so the interruption reaches the caller.
    @Test func doorbellWaitInterruptedBySignalIsRetriedNotBroken() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("k3sm-sdk-bell-eintr-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/budget.bell"
        #expect(FileManager.default.createFile(atPath: path, contents: Data([0])))
        let bell = try Doorbell(path: path)

        // This is the only user of SIGUSR1 in the test target; it relies on the suite being serialized.
        var action = sigaction()
        action.__sigaction_u.__sa_handler = { _ in }
        action.sa_flags = 0
        sigemptyset(&action.sa_mask)
        var previous = sigaction()
        try #require(sigaction(SIGUSR1, &action, &previous) == 0, "helper: sigaction errno \(errno)")
        var restorePrevious = true
        defer { if restorePrevious { _ = sigaction(SIGUSR1, &previous, nil) } }

        let state = InterruptedWait()
        let waiter = Thread {
            // The test runner's threads start with SIGUSR1 blocked, and a
            // blocked signal never interrupts the wait, so the waiter
            // unblocks it for itself before it publishes.
            var usr1 = sigset_t()
            sigemptyset(&usr1)
            sigaddset(&usr1, SIGUSR1)
            let maskRC = pthread_sigmask(SIG_UNBLOCK, &usr1, nil)
            if maskRC != 0 {
                state.maskFailed.store(maskRC, ordering: .releasing)
                state.result.store(3, ordering: .releasing)
                return
            }
            state.thread.store(UInt(bitPattern: pthread_self()), ordering: .releasing)
            state.aboutToWait.store(true, ordering: .releasing)
            let ok = bell.wait(nanoseconds: 5_000_000_000)
            // Block SIGUSR1 again before publishing, so a late signal stays
            // pending here and never runs once the handler is restored.
            _ = pthread_sigmask(SIG_BLOCK, &usr1, nil)
            state.endedAt.store(clock_gettime_nsec_np(CLOCK_UPTIME_RAW), ordering: .releasing)
            state.result.store(ok ? 1 : 2, ordering: .releasing)
            // Stay alive until the test thread has stopped signalling, so
            // every pthread_kill targets a live thread.
            while !state.release.load(ordering: .acquiring) { usleep(1_000) }
        }
        waiter.start()

        // The waiter publishes its pthread and then that it is about to wait; give it a bound.
        let publishDeadline = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + 5_000_000_000
        while !state.aboutToWait.load(ordering: .acquiring), state.result.load(ordering: .acquiring) == 0,
            clock_gettime_nsec_np(CLOCK_UPTIME_RAW) < publishDeadline
        {
            usleep(1_000)
        }
        let maskFailed = state.maskFailed.load(ordering: .acquiring)
        try #require(maskFailed == 0, "helper: pthread_sigmask returned \(maskFailed)")
        let published = state.thread.load(ordering: .acquiring)
        guard state.aboutToWait.load(ordering: .acquiring), published != 0,
            let target = pthread_t(bitPattern: published)
        else {
            state.release.store(true, ordering: .releasing)
            restorePrevious = false
            _ = signal(SIGUSR1, SIG_IGN)
            try #require(Bool(false), "helper: the waiter thread never reached its wait")
            return
        }
        usleep(20_000)

        // A signal that lands before the thread is inside kevent only runs the
        // handler, so it is sent again every 50 ms, for up to about 2 s, until
        // the wait ends.
        let firstSignal = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let signalDeadline = firstSignal + 2_000_000_000
        var sent = 0
        var killFailed: Int32 = 0
        while state.result.load(ordering: .acquiring) == 0,
            clock_gettime_nsec_np(CLOCK_UPTIME_RAW) < signalDeadline
        {
            let rc = pthread_kill(target, SIGUSR1)
            if rc != 0 {
                killFailed = rc
                break
            }
            sent += 1
            for _ in 0..<50 where state.result.load(ordering: .acquiring) == 0 { usleep(1_000) }
        }
        // Signalling is over: let the waiter exit, then join it before the
        // handler is restored. The wait's ceiling is 5 s.
        state.release.store(true, ordering: .releasing)
        let joinDeadline = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + 8_000_000_000
        while !waiter.isFinished, clock_gettime_nsec_np(CLOCK_UPTIME_RAW) < joinDeadline { usleep(1_000) }
        let finished = waiter.isFinished
        if !finished {
            // The default action would terminate the test process, so a
            // waiter still running is left with the signal ignored.
            restorePrevious = false
            _ = signal(SIGUSR1, SIG_IGN)
        }
        try #require(finished, "helper: the waiter thread did not finish within 8 s")
        #expect(killFailed == 0, "helper: pthread_kill returned \(killFailed)")
        print("doorbell EINTR wait: \(sent) signal(s) sent")

        let result = state.result.load(ordering: .acquiring)
        let endedAt = state.endedAt.load(ordering: .acquiring)
        #expect(result == 1, "the interrupted wait returned false (result \(result))")
        #expect(!bell.isBroken)
        #expect(endedAt >= firstSignal, "the wait ended before the first signal was sent")
        if endedAt >= firstSignal {
            #expect(
                endedAt - firstSignal < 2_000_000_000,
                "the wait ended \((endedAt - firstSignal) / 1_000_000) ms after the first signal")
        }
    }
}

/// The interrupted doorbell wait's shared state: the waiter's pthread as a
/// bit pattern (0 until published), whether it is about to wait, when the
/// wait ended on the uptime clock, its result (0 still waiting, 1 true,
/// 2 false, 3 setup failed), and the test thread's release of the waiter.
private final class InterruptedWait: Sendable {
    /// The waiter's pthread_sigmask error, 0 when SIGUSR1 was unblocked.
    let maskFailed = Atomic<Int32>(0)
    let thread = Atomic<UInt>(0)
    let aboutToWait = Atomic<Bool>(false)
    let endedAt = Atomic<UInt64>(0)
    let result = Atomic<UInt8>(0)
    /// Set by the test thread once it has stopped signalling; the waiter exits only after it.
    let release = Atomic<Bool>(false)
}

/// When the ringer thread wrote the doorbell, on the uptime clock; 0 until then.
private final class RingTime: Sendable {
    let at = Atomic<UInt64>(0)
    /// True when the ringer thread could not open or write the doorbell file.
    let failed = Atomic<Bool>(false)
}

/// The calling thread's CPU time in nanoseconds.
private func threadCPUNanoseconds() -> UInt64 {
    var ts = timespec()
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
    return UInt64(ts.tv_sec) * 1_000_000_000 + UInt64(ts.tv_nsec)
}
