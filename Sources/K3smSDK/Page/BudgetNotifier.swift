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
import Synchronization
internal import CK3smPage

/// Tells a reader when the budget page changed in a way worth acting on.
///
/// The writer bumps the page's `notifyEpoch` word only on a change of
/// level, admit, a threshold or the generation, never for a routine sample,
/// and wakes the threads waiting on that word. A notifier waits on it with
/// `os_sync_wait_on_address_with_timeout` and `OS_SYNC_WAIT_ON_ADDRESS_SHARED`
/// on the shared read-only mapping, so a writer in another process wakes it.
/// When the producer provides a doorbell file instead, pass its path and the
/// notifier waits on that file with kqueue (`EVFILT_VNODE`, `NOTE_WRITE`) in
/// slices of at most 100 ms, checking the word between them, so a bump whose
/// doorbell write failed is still seen within one slice. When the kqueue
/// wait itself fails, the notifier stops using it and sleeps between checks
/// of the word, in slices of the same length.
/// No socket is used. A reader that wants every sample polls `read()`.
///
/// The notifier remembers the last epoch it reported, starting from the
/// epoch at `init`: `poll()` and `wait(timeout:)` report a change since then
/// and move it forward. Epochs wrap, so compare them for inequality only.
/// Several bumps between two looks are one reported change (a coalesce), and
/// the reported epoch is the newest. Give each waiting thread its own
/// notifier; `changes()` uses its own thread and state.
public final class BudgetNotifier: Sendable {
    /// The page this notifier watches.
    public let page: BudgetPage
    /// The doorbell file the producer provides, when one was given.
    public let doorbellPath: String?

    private let lastSeen: Mutex<UInt64>
    let doorbell: Doorbell?

    /// How long the `changes()` thread waits before it checks whether its
    /// stream was cancelled.
    static let feederSlice: Duration = .milliseconds(100)
    /// The longest a doorbell wait blocks before the epoch word is checked
    /// again: the worst-case delay for a bump whose doorbell never rings, or
    /// whose ring was lost, and the sleep between checks once the doorbell is
    /// broken. The cost is up to 10 wakeups a second per blocked waiter; a
    /// shorter slice sees a lost ring sooner and wakes more often.
    static let doorbellSlice: Duration = .milliseconds(100)
    /// The longest one address wait is given; the loop re-checks the
    /// deadline, so a kernel that times a huge timeout out at once cannot spin.
    static let maxWordWait: UInt64 = 24 * 60 * 60 * 1_000_000_000
    /// The longest sleep after a failed address wait before the word is
    /// polled again, in nanoseconds.
    static let failedWordWaitSleep: UInt64 = 10_000_000
    /// The number of `changes()` threads running, for the tests.
    static let liveFeeders = Atomic<Int>(0)

    /// A notifier for `page`. With `doorbellPath`, the doorbell file the
    /// producer provides is opened for kqueue; failing that throws
    /// `notFound` with the errno. The open never blocks, and anything but a
    /// regular file is `notFound` with the values `BudgetPage.open(path:)`
    /// uses: `EISDIR` for a directory and `EINVAL` for any other
    /// non-regular file, such as a FIFO.
    public init(_ page: BudgetPage, doorbellPath: String? = nil) throws(BudgetError) {
        self.page = page
        self.doorbellPath = doorbellPath
        lastSeen = Mutex(page.loadNotifyEpoch())
        if let doorbellPath {
            doorbell = try Doorbell(path: doorbellPath)
        } else {
            doorbell = nil
        }
    }

    /// The last epoch this notifier reported, or the epoch at `init`.
    public var notifyEpoch: UInt64 { lastSeen.withLock { $0 } }

    /// Sets the last reported epoch to `epoch`, the `notifyEpoch` of a
    /// snapshot the caller already read. A bump between that read and this
    /// notifier's `init` is then reported by the next `poll()` or
    /// `wait(timeout:)` instead of being taken as already seen. Any epoch
    /// different from the live word, one ahead of it included, makes the
    /// next `poll()` or `wait(timeout:)` report a change once; the live
    /// epoch reports nothing. A `changes()` stream already running keeps
    /// its own epoch and is not affected.
    ///
    /// The epoch is set under the notifier's lock, so calling this from any
    /// thread is safe. A `wait(timeout:)` already in progress is not
    /// affected: it compares against the epoch it read when it started, and
    /// when it returns a change it overwrites the seeded epoch with that
    /// change. For a predictable result, seed before the first `poll()` or
    /// `wait(timeout:)`. Unlike the C++ SDK's `seed`, which must be called
    /// before the first poll or wait on the waiting thread, this one is safe
    /// to call from any thread.
    public func seed(_ epoch: UInt64) {
        lastSeen.withLock { $0 = epoch }
    }

    /// The new `notifyEpoch` when it changed since the last report, else
    /// nil. It never blocks.
    public func poll() -> UInt64? {
        let now = page.loadNotifyEpoch()
        return lastSeen.withLock { seen in
            guard now != seen else { return nil }
            seen = now
            return now
        }
    }

    /// Blocks until `notifyEpoch` differs from the last report, or `timeout`
    /// runs out, and returns the new epoch, or nil on a timeout. A wake with
    /// no epoch change (a routine sample, or a spurious wake) is not a
    /// change: the wait goes on until the timeout. A zero timeout is `poll()`.
    ///
    /// This blocks its thread in the kernel. Never call it on the Swift
    /// concurrency pool, whose threads must not block; call it on a thread
    /// of your own, or iterate `changes()`.
    @available(*, noasync, message: "wait(timeout:) blocks its thread; use a dedicated thread or changes()")
    public func wait(timeout: Duration) -> UInt64? {
        let from = notifyEpoch
        guard let e = Self.waitForChange(page, doorbell: doorbell, from: from, timeout: timeout) else { return nil }
        lastSeen.withLock { $0 = e }
        return e
    }

    /// A stream of page reads: the current one first, then one after each
    /// `notifyEpoch` change. A read that is `torn` or `stale` is retried
    /// once, one writer period later, and the stream yields that second
    /// result, error or snapshot. A writer that goes silent bumps no epoch,
    /// so the stream also yields the `stale` error once the last snapshot
    /// passes the page's staleness rule, and the next fresh read after that.
    /// One dedicated thread feeds the stream and
    /// ends when the stream is cancelled or dropped. Only the newest element
    /// is buffered for a slow consumer, so it always sees the latest state.
    /// When the doorbell cannot be reopened for the thread, it waits on the
    /// word instead.
    public func changes() -> AsyncStream<Result<BudgetSnapshot, BudgetError>> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: Result<BudgetSnapshot, BudgetError>.self, bufferingPolicy: .bufferingNewest(1))
        let stop = Atomic<Bool>.Box()
        continuation.onTermination = { _ in stop.value.store(true, ordering: .releasing) }
        let page = page
        let doorbell = doorbellPath.flatMap { try? Doorbell(path: $0) }
        let thread = Thread {
            Self.liveFeeders.add(1, ordering: .relaxed)
            defer { Self.liveFeeders.subtract(1, ordering: .relaxed) }
            Self.feed(page, doorbell: doorbell, stop: stop, into: continuation)
            continuation.finish()
        }
        thread.name = "k3sm budget notifier"
        thread.start()
        return stream
    }

    /// The `changes()` thread's loop.
    private static func feed(
        _ page: BudgetPage, doorbell: Doorbell?, stop: Atomic<Bool>.Box,
        into continuation: AsyncStream<Result<BudgetSnapshot, BudgetError>>.Continuation
    ) {
        var period: Int64 = 1
        // When the last yield was a snapshot: the wall-clock second after
        // which the page's staleness rule can call it stale. A hint for when
        // to look again; read() decides.
        var freshUntil: Int64?
        // When the last yield was an error: that error. While it is set the
        // page is read again every slice, so a recovery, or a change to
        // another error, is yielded even with no epoch bump, and the
        // staleness check above resumes after the next snapshot.
        var lastFailure: BudgetError?
        func stopped() -> Bool { stop.value.load(ordering: .acquiring) }
        // Yields a read; a failure equal to `unless` (the last error
        // yielded) is not yielded again.
        func emit(unless: BudgetError? = nil) -> Bool {
            var r = page.read()
            if case .failure(let e) = r, e == .torn || e == .stale {
                // One re-read, one writer period later.
                let until = ContinuousClock.now + .seconds(period)
                while ContinuousClock.now < until {
                    if stopped() { return false }
                    Thread.sleep(forTimeInterval: min(0.1, (until - ContinuousClock.now).seconds))
                }
                r = page.read()
            }
            if case .failure(let e) = r, e == unless { return true }
            note(r)
            if case .terminated = continuation.yield(r) { return false }
            return true
        }
        func note(_ r: Result<BudgetSnapshot, BudgetError>) {
            switch r {
            case .success(let s):
                period = s.writerPeriodSeconds
                freshUntil = staleAfter(s)
                lastFailure = nil
            case .failure(let e):
                freshUntil = nil
                lastFailure = e
            }
        }

        var epoch = page.loadNotifyEpoch()
        guard emit() else { return }
        while !stopped() {
            if let e = waitForChange(page, doorbell: doorbell, from: epoch, timeout: feederSlice) {
                epoch = e
                guard emit() else { return }
                continue
            }
            // No epoch change. A writer that went silent never bumps the
            // epoch, so the page's staleness rule is checked here: a
            // snapshot past its fresh window is read again and, when stale,
            // yielded as such; after an error yield (stale, torn, corrupt or
            // any other), the first fresh read, or a different error, is
            // yielded.
            if let until = freshUntil, wallSeconds() > until {
                switch page.read() {
                case .success(let s):
                    note(.success(s)) // the writer is alive: nothing to yield
                case .failure:
                    guard emit() else { return }
                }
            } else if let last = lastFailure {
                switch page.read() {
                case .success:
                    guard emit(unless: last) else { return }
                case .failure(let e) where e != last:
                    guard emit(unless: last) else { return }
                case .failure:
                    break
                }
            }
        }
    }

    /// The last wall-clock second at which `s` is not stale by the page's
    /// rule (age above `staleFactor` writer periods), saturating.
    private static func staleAfter(_ s: BudgetSnapshot) -> Int64 {
        let (limit, o1) = PageLayout.staleFactor.multipliedReportingOverflow(by: s.writerPeriodSeconds)
        if o1 { return .max }
        let (until, o2) = s.observedAt.addingReportingOverflow(limit)
        return o2 ? (limit > 0 ? .max : .min) : until
    }

    /// The wall clock in Unix seconds, the clock read() checks staleness on.
    private static func wallSeconds() -> Int64 {
        var ts = timespec()
        clock_gettime(CLOCK_REALTIME, &ts)
        return Int64(ts.tv_sec)
    }

    /// Waits until the epoch differs from `from` or the timeout runs out.
    private static func waitForChange(
        _ page: BudgetPage, doorbell: Doorbell?, from: UInt64, timeout: Duration
    ) -> UInt64? {
        // A timeout past the end of the clock saturates: the wait has no
        // deadline.
        let (end, overflow) = clock_gettime_nsec_np(CLOCK_UPTIME_RAW).addingReportingOverflow(timeout.nanoseconds)
        let deadline = overflow ? UInt64.max : end
        while true {
            let e = page.loadNotifyEpoch()
            if e != from { return e }
            let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            guard now < deadline else { return nil }
            let remaining = deadline - now
            if let doorbell {
                // The doorbell is an extra wake source, never the only one:
                // its write can fail or never happen, so the word is checked
                // again at least every doorbellSlice. A doorbell whose wait
                // failed is not waited on again: the word is polled instead,
                // so a failing kevent cannot spin.
                let slice = doorbellWaitSlice(remaining: remaining)
                if doorbell.isBroken || !doorbell.wait(nanoseconds: slice) {
                    doorbell.markBroken()
                    usleep(useconds_t(slice / 1000))
                }
                continue
            }
            switch ck3sm_page_wait_word(page.base, PageLayout.notifyEpoch, from, wordWaitSlice(remaining: remaining)) {
            case 0, ETIMEDOUT, EINTR:
                continue
            default:
                // The wait itself failed: fall back to polling the word.
                usleep(useconds_t(failedWaitSleep(remaining: remaining) / 1000))
            }
        }
    }

    /// The longest one doorbell wait blocks, in nanoseconds: `remaining`
    /// clamped to `doorbellSlice`.
    static func doorbellWaitSlice(remaining: UInt64) -> UInt64 {
        min(remaining, doorbellSlice.nanoseconds)
    }

    /// The timeout one address wait on the epoch word is given, in
    /// nanoseconds: `remaining` clamped to `maxWordWait`.
    static func wordWaitSlice(remaining: UInt64) -> UInt64 {
        min(remaining, maxWordWait)
    }

    /// The sleep after a failed address wait, in nanoseconds: `remaining`
    /// clamped to `failedWordWaitSleep`.
    static func failedWaitSleep(remaining: UInt64) -> UInt64 {
        min(remaining, failedWordWaitSleep)
    }
}

extension BudgetPage {
    /// The page's notifyEpoch word, loaded acquiring.
    func loadNotifyEpoch() -> UInt64 { ck3sm_page_load_acquire(base, PageLayout.notifyEpoch) }
}

extension Atomic where Value == Bool {
    /// A shared atomic flag.
    final class Box: Sendable {
        let value = Atomic<Bool>(false)
    }
}

/// A kqueue watching the producer's doorbell file for writes.
final class Doorbell: Sendable {
    private let fd: Int32
    private let kq: Int32
    private let broken = Atomic<Bool>(false)

    init(path: String) throws(BudgetError) {
        // O_NONBLOCK keeps a FIFO without a writer from blocking the open;
        // the type check below then refuses it.
        fd = path.withCString { open($0, O_EVTONLY | O_NONBLOCK | O_CLOEXEC) }
        guard fd >= 0 else { throw .notFound(errno: errno) }
        var st = stat()
        guard fstat(fd, &st) == 0 else {
            let err = errno
            close(fd)
            throw .notFound(errno: err)
        }
        guard st.st_mode & S_IFMT == S_IFREG else {
            close(fd)
            throw .notFound(errno: st.st_mode & S_IFMT == S_IFDIR ? EISDIR : EINVAL)
        }
        kq = kqueue()
        guard kq >= 0 else {
            let err = errno
            close(fd)
            throw .notFound(errno: err)
        }
        var ev = kevent(
            ident: UInt(fd), filter: Int16(EVFILT_VNODE), flags: UInt16(EV_ADD | EV_CLEAR),
            fflags: UInt32(NOTE_WRITE | NOTE_EXTEND), data: 0, udata: nil)
        guard kevent(kq, &ev, 1, nil, 0, nil) == 0 else {
            let err = errno
            close(kq)
            close(fd)
            throw .notFound(errno: err)
        }
    }

    deinit {
        close(kq)
        close(fd)
    }

    /// Whether a wait on this doorbell has failed; it is not waited on again.
    var isBroken: Bool { broken.load(ordering: .relaxed) }

    /// Marks the doorbell as one that cannot be waited on.
    func markBroken() { broken.store(true, ordering: .relaxed) }

    /// A test hook: puts the doorbell file's descriptor over the kqueue
    /// descriptor with `dup2`, so every later kevent wait on it fails. Both
    /// numbers stay open, and the destructor closes both. The `dup2` runs
    /// outside the `precondition`, so a build that does not evaluate
    /// preconditions still swaps the descriptor.
    func breakQueueForTesting() {
        let rc = dup2(fd, kq)
        precondition(rc >= 0, "dup2 over the kqueue descriptor failed")
    }

    /// Blocks until the doorbell is written or the time runs out. A write
    /// between the caller's check and this call is kept by the kqueue, so
    /// it is not lost. Returns false when the wait failed (an error other
    /// than EINTR, or an `EV_ERROR` event), so the doorbell cannot be used.
    func wait(nanoseconds: UInt64) -> Bool {
        var ts = timespec(tv_sec: Int(nanoseconds / 1_000_000_000), tv_nsec: Int(nanoseconds % 1_000_000_000))
        var ev = kevent()
        let rc = kevent(kq, nil, 0, &ev, 1, &ts)
        if rc < 0 { return errno == EINTR }
        return rc == 0 || ev.flags & UInt16(EV_ERROR) == 0
    }
}

extension Duration {
    /// The duration in whole nanoseconds, 0 when negative, saturating.
    fileprivate var nanoseconds: UInt64 {
        let (s, a) = components
        guard s >= 0 else { return 0 }
        let (ns, o) = UInt64(s).multipliedReportingOverflow(by: 1_000_000_000)
        return o ? .max : ns &+ UInt64(a / 1_000_000_000)
    }

    /// The duration in seconds, as a double.
    fileprivate var seconds: Double {
        let (s, a) = components
        return Double(s) + Double(a) / 1e18
    }
}
