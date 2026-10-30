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
/// notifier waits on that file with kqueue (`EVFILT_VNODE`, `NOTE_WRITE`).
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
    private let doorbell: Doorbell?

    /// How long the `changes()` thread waits before it checks whether its
    /// stream was cancelled.
    static let feederSlice: Duration = .milliseconds(100)
    /// The number of `changes()` threads running, for the tests.
    static let liveFeeders = Atomic<Int>(0)

    /// A notifier for `page`. With `doorbellPath`, the doorbell file the
    /// producer provides is opened for kqueue; failing that throws
    /// `notFound` with the errno.
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
    /// result, error or snapshot. One dedicated thread feeds the stream and
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
        func stopped() -> Bool { stop.value.load(ordering: .acquiring) }
        func emit() -> Bool {
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
            if case .success(let s) = r { period = s.writerPeriodSeconds }
            if case .terminated = continuation.yield(r) { return false }
            return true
        }

        var epoch = page.loadNotifyEpoch()
        guard emit() else { return }
        while !stopped() {
            guard let e = waitForChange(page, doorbell: doorbell, from: epoch, timeout: feederSlice) else { continue }
            epoch = e
            guard emit() else { return }
        }
    }

    /// Waits until the epoch differs from `from` or the timeout runs out.
    private static func waitForChange(
        _ page: BudgetPage, doorbell: Doorbell?, from: UInt64, timeout: Duration
    ) -> UInt64? {
        let deadline = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) &+ timeout.nanoseconds
        while true {
            let e = page.loadNotifyEpoch()
            if e != from { return e }
            let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            guard now < deadline else { return nil }
            let remaining = deadline - now
            if let doorbell {
                doorbell.wait(nanoseconds: remaining)
                continue
            }
            switch ck3sm_page_wait_word(page.base, PageLayout.notifyEpoch, from, remaining) {
            case 0, ETIMEDOUT, EINTR:
                continue
            default:
                // The wait itself failed: fall back to polling the word.
                usleep(useconds_t(min(remaining, 10_000_000) / 1000))
            }
        }
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
private final class Doorbell: Sendable {
    private let fd: Int32
    private let kq: Int32

    init(path: String) throws(BudgetError) {
        fd = path.withCString { open($0, O_EVTONLY | O_CLOEXEC) }
        guard fd >= 0 else { throw .notFound(errno: errno) }
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

    /// Blocks until the doorbell is written or the time runs out. A write
    /// between the caller's check and this call is kept by the kqueue, so
    /// it is not lost.
    func wait(nanoseconds: UInt64) {
        var ts = timespec(tv_sec: Int(nanoseconds / 1_000_000_000), tv_nsec: Int(nanoseconds % 1_000_000_000))
        var ev = kevent()
        _ = kevent(kq, nil, 0, &ev, 1, &ts)
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
