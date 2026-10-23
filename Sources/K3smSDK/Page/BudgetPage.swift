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

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Synchronization

/// A read-only mapping of the node budget page.
///
/// `open(path:)` maps the page and checks its header once; `read()` copies
/// the body under the writer's seqlock. The read path reads no environment
/// and allocates only the snapshot's node name and arrays. A page is never
/// renamed or truncated by its writer, so the mapping stays valid for the
/// life of the object.
public final class BudgetPage: @unchecked Sendable {
    // @unchecked: the mapping is immutable after init and only ever read,
    // through atomic loads, so sharing the object across threads is safe.

    /// Where a native Darwin pod finds the page.
    public static let darwinPagePath = "/var/lib/k3sm/budget/budget.v1.page"
    /// Where a Linux reader finds the page: a vm guest, or a pod on a Linux
    /// producer's node.
    public static let linuxPagePath = "/run/k3sm/budget/budget.v1.page"
    /// The page path for the platform this SDK is built for.
    #if os(Linux)
    public static let defaultPagePath = linuxPagePath
    #else
    public static let defaultPagePath = darwinPagePath
    #endif

    /// The path the page was opened from.
    public let path: String
    /// The ABI major of the page (always the one this SDK reads).
    public let abiMajor: UInt16
    /// The ABI minor of the page. A higher minor than this SDK knows is read
    /// up to the fields this SDK knows.
    public let abiMinor: UInt16
    /// The page's header size in bytes.
    public let headerSize: UInt32
    /// The page's body size in bytes, the region the seqlock covers.
    public let bodySize: UInt32

    private let base: UnsafeRawPointer
    private let length: Int

    private init(path: String, base: UnsafeRawPointer, length: Int, header: (UInt16, UInt16, UInt32, UInt32)) {
        self.path = path
        self.base = base
        self.length = length
        (abiMajor, abiMinor, headerSize, bodySize) = header
    }

    deinit {
        _ = munmap(UnsafeMutableRawPointer(mutating: base), length)
    }

    /// Maps the page at `path` read-only and checks its header.
    public static func open(path: String) throws(BudgetError) -> BudgetPage {
        let fd = path.withCString { Darwin.open($0, O_RDONLY | O_CLOEXEC) }
        guard fd >= 0 else { throw .notFound(errno: errno) }
        defer { _ = close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw .notFound(errno: errno) }
        let size = Int(st.st_size)
        guard size >= PageLayout.seq else { throw .truncated }
        let length = min(size, PageLayout.pageSize)
        guard let m = mmap(nil, length, PROT_READ, MAP_SHARED, fd, 0), m != MAP_FAILED else {
            throw .notFound(errno: errno)
        }
        let p = UnsafeRawPointer(m)
        let header: (UInt16, UInt16, UInt32, UInt32)
        do {
            header = try checkHeader(p, length: length)
        } catch {
            _ = munmap(m, length)
            throw error
        }
        return BudgetPage(path: path, base: p, length: length, header: header)
    }

    /// The header checks, in the contract's order. The header line is
    /// constant once the writer has formatted the page.
    private static func checkHeader(_ p: UnsafeRawPointer, length: Int) throws(BudgetError)
        -> (UInt16, UInt16, UInt32, UInt32)
    {
        for (i, b) in PageLayout.magic.enumerated() where p.load(fromByteOffset: i, as: UInt8.self) != b {
            throw .abiMismatch
        }
        let major = UInt16(littleEndian: p.loadUnaligned(fromByteOffset: PageLayout.abiMajorOffset, as: UInt16.self))
        let minor = UInt16(littleEndian: p.loadUnaligned(fromByteOffset: PageLayout.abiMinorOffset, as: UInt16.self))
        let header = UInt32(littleEndian: p.loadUnaligned(fromByteOffset: PageLayout.headerSizeOffset, as: UInt32.self))
        let body = UInt32(littleEndian: p.loadUnaligned(fromByteOffset: PageLayout.bodySizeOffset, as: UInt32.self))
        guard major == PageLayout.abiMajor, header == PageLayout.headerSize else { throw .abiMismatch }
        guard body >= PageLayout.knownBodySize, length >= Int(header) + Int(body) else { throw .truncated }
        return (major, minor, header, body)
    }

    /// Reads a stable snapshot of the page, checked for staleness against
    /// the wall clock.
    public func read() -> Result<BudgetSnapshot, BudgetError> {
        var ts = timespec()
        clock_gettime(CLOCK_REALTIME, &ts)
        return read(now: Int64(ts.tv_sec))
    }

    /// Reads a stable snapshot, checked for staleness at `now` (Unix seconds).
    func read(now: Int64) -> Result<BudgetSnapshot, BudgetError> {
        read(now: now, afterAttempt: { _ in })
    }

    @inline(__always)
    private func word(_ offset: Int) -> UnsafePointer<Atomic<UInt64>> {
        (base + offset).assumingMemoryBound(to: Atomic<UInt64>.self)
    }

    /// The seqlock read: seq loaded acquiring (odd: the writer is mid-write,
    /// try again), every body word loaded relaxed into a local copy, an
    /// acquiring fence, seq reloaded relaxed and compared. After
    /// `PageLayout.readerRetries` attempts the read is torn. `afterAttempt`
    /// runs after each attempt's loads and before its second seq load, with
    /// the attempt number; tests script a writer through it.
    func read(now: Int64, afterAttempt: (Int) -> Void) -> Result<BudgetSnapshot, BudgetError> {
        withUnsafeTemporaryAllocation(of: UInt64.self, capacity: PageLayout.bodyWords) { buf in
            let seqWord = word(PageLayout.seq)
            for attempt in 0..<PageLayout.readerRetries {
                let s1 = seqWord.pointee.load(ordering: .acquiring)
                if s1 & 1 == 1 {
                    afterAttempt(attempt)
                    continue
                }
                for i in 0..<PageLayout.bodyWords {
                    buf[i] = word(PageLayout.headerSize + 8 * i).pointee.load(ordering: .relaxed)
                }
                afterAttempt(attempt)
                atomicMemoryFence(ordering: .acquiring)
                let s2 = seqWord.pointee.load(ordering: .relaxed)
                guard s1 == s2 else { continue }
                let epoch = word(PageLayout.notifyEpoch).pointee.load(ordering: .relaxed)
                return PageDecoder(words: UnsafeBufferPointer(buf)).snapshot(seq: s1, notifyEpoch: epoch, now: now)
            }
            return .failure(.torn)
        }
    }
}

/// Decodes a stable copy of the body words. Offsets are page offsets.
private struct PageDecoder {
    let words: UnsafeBufferPointer<UInt64>

    func u64(_ offset: Int) -> UInt64 { UInt64(littleEndian: words[(offset - PageLayout.headerSize) / 8]) }
    func i64(_ offset: Int) -> Int64 { Int64(bitPattern: u64(offset)) }
    func opt(_ offset: Int) -> Int64? {
        let v = i64(offset)
        return v == PageLayout.absent ? nil : v
    }

    /// A code of a structural table: an unknown code is an ABI mismatch,
    /// because this reader cannot name the value.
    func structural<T>(_ offset: Int, _ table: [T]) throws(BudgetError) -> T? {
        let c = u64(offset)
        if c == 0 { return nil }
        guard c <= UInt64(table.count) else { throw .abiMismatch }
        return table[Int(c - 1)]
    }

    /// A code of a producer-vocabulary table: an unknown code reads as the
    /// type's unknown value.
    func vocabulary<T>(_ offset: Int, _ table: [T], unknown: T) -> T? {
        let c = u64(offset)
        if c == 0 { return nil }
        return c <= UInt64(table.count) ? table[Int(c - 1)] : unknown
    }

    func snapshot(seq: UInt64, notifyEpoch: UInt64, now: Int64) -> Result<BudgetSnapshot, BudgetError> {
        do throws(BudgetError) {
            let s = try decode(seq: seq, notifyEpoch: notifyEpoch)
            return isStale(s, now: now) ? .failure(.stale) : .success(s)
        } catch {
            return .failure(error)
        }
    }

    private func isStale(_ s: BudgetSnapshot, now: Int64) -> Bool {
        let (limit, o1) = PageLayout.staleFactor.multipliedReportingOverflow(by: s.writerPeriodSeconds)
        let (age, o2) = now.subtractingReportingOverflow(s.observedAt)
        if o2 { return s.observedAt < now }
        return !o1 && age > limit
    }

    private func decode(seq: UInt64, notifyEpoch: UInt64) throws(BudgetError) -> BudgetSnapshot {
        let n = u64(PageLayout.nodeNameLen)
        guard n <= UInt64(PageLayout.maxNodeNameBytes) else { throw .corrupt }
        let raw = UnsafeRawBufferPointer(words)
        let nameStart = PageLayout.nodeName - PageLayout.headerSize
        guard let nodeName = String(validating: raw[nameStart..<nameStart + Int(n)], as: UTF8.self) else {
            throw .corrupt
        }
        let period = i64(PageLayout.writerPeriodSeconds)
        guard period >= 1 else { throw .corrupt }
        guard let platform = try structural(PageLayout.platform, PageLayout.platformCodes),
              let level = try structural(PageLayout.level, PageLayout.levelCodes)
        else { throw .corrupt }

        let c = PageLayout.capacity
        let capacity = NodeBudget.Capacity(
            cpuCapacityMilli: opt(c), cpuSystemReserveMilli: opt(c + 8), memCapacityBytes: opt(c + 16),
            memSystemReserveBytes: opt(c + 24), memEvictionReserveBytes: opt(c + 32),
            memAllocatableBytes: opt(c + 40), swapTotalBytes: opt(c + 48), swapUsedBytes: opt(c + 56))

        var darwin: NodeBudget.DarwinSignals?
        if platform == .darwin {
            let d = PageLayout.darwin
            var compressor: NodeBudget.DarwinCompressor? = NodeBudget.DarwinCompressor(
                bytesUsed: opt(d + 16), bytesStored: opt(d + 24), segmentLimitBytes: opt(d + 32))
            if compressor == NodeBudget.DarwinCompressor() { compressor = nil }
            darwin = NodeBudget.DarwinSignals(
                vmPressureLevel: opt(d), memorystatusLevelPermille: opt(d + 8), compressor: compressor,
                swapinsTotal: opt(d + 40), swapoutsTotal: opt(d + 48))
        }

        var linux: NodeBudget.LinuxSignals?
        do {
            var off = PageLayout.linuxPSI
            func line() -> NodeBudget.PSILine? {
                let l = NodeBudget.PSILine(avg10Permille: opt(off), avg60Permille: opt(off + 8), totalUs: opt(off + 16))
                off += 24
                return l == NodeBudget.PSILine() ? nil : l
            }
            func resource() -> NodeBudget.PSIResource? {
                let some = line()
                let r = NodeBudget.PSIResource(some: some, full: line())
                return r == NodeBudget.PSIResource() ? nil : r
            }
            let cpu = resource()
            let memory = resource()
            var psi: NodeBudget.LinuxPSI? = NodeBudget.LinuxPSI(cpu: cpu, memory: memory, io: resource())
            if psi == NodeBudget.LinuxPSI() { psi = nil }
            let e = PageLayout.linuxMemoryEvents
            var events: NodeBudget.MemoryEvents? = NodeBudget.MemoryEvents(
                high: opt(e), max: opt(e + 8), oom: opt(e + 16), oomKill: opt(e + 24))
            if events == NodeBudget.MemoryEvents() { events = nil }
            let l = NodeBudget.LinuxSignals(psi: psi, memoryEvents: events)
            if platform == .linux || l != NodeBudget.LinuxSignals() { linux = l }
        }

        var signals: [NodeBudget.Signal] = []
        signals.reserveCapacity(PageLayout.signalSlots)
        for slot in 0..<PageLayout.signalSlots {
            let b = PageLayout.signals + slot * PageLayout.signalStride
            guard let id = try structural(b, PageLayout.signalCodes) else { continue }
            guard let unit = try structural(b + 8, PageLayout.unitCodes) else { throw .corrupt }
            signals.append(NodeBudget.Signal(
                id: id, unit: unit, value: opt(b + 16),
                warnThreshold: opt(b + 24), admitStopThreshold: opt(b + 32), criticalThreshold: opt(b + 40),
                evictSoftThreshold: opt(b + 48), evictHardThreshold: opt(b + 56),
                warnRelease: opt(b + 64), admitStopRelease: opt(b + 72), criticalRelease: opt(b + 80),
                evictSoftRelease: opt(b + 88), evictHardRelease: opt(b + 96),
                graceSeconds: opt(b + 104), minReclaimBytes: opt(b + 112), windowSeconds: opt(b + 120),
                etaToNextRungSeconds: opt(b + 128),
                trend: vocabulary(b + 136, PageLayout.trendCodes, unknown: .unknown),
                limitingResource: vocabulary(b + 144, PageLayout.limitingResourceCodes, unknown: .unknown),
                sharedWith: try structural(b + 152, PageLayout.signalCodes)))
        }

        var counters: [BudgetSnapshot.BandCounters] = []
        counters.reserveCapacity(PageLayout.counterSlots)
        for slot in 0..<PageLayout.counterSlots {
            let b = PageLayout.counters + slot * PageLayout.counterStride
            guard let band = try structural(b, PageLayout.bandCodes) else { continue }
            counters.append(BudgetSnapshot.BandCounters(
                band: band, evictionsTotal: i64(b + 8), oomKillsTotal: i64(b + 16), kernelKillsTotal: i64(b + 24),
                restartsTotal: i64(b + 32), memHighEventsTotal: i64(b + 40), tier1RefusedTotal: i64(b + 48)))
        }

        return BudgetSnapshot(
            seq: seq,
            notifyEpoch: notifyEpoch,
            generation: i64(PageLayout.generation),
            writerPeriodSeconds: period,
            observedAt: i64(PageLayout.observedAt),
            platform: platform,
            nodeName: nodeName,
            capacity: capacity,
            level: level,
            darwin: darwin,
            linux: linux,
            signals: signals,
            admit: u64(PageLayout.admit) == 1,
            admitReasonSignal: try structural(PageLayout.admitReasonSignal, PageLayout.signalCodes),
            evictDeadline: opt(PageLayout.evictDeadline),
            killMode: BudgetSnapshot.KillMode(
                mode: try structural(PageLayout.killModeMode, PageLayout.killModeCodes),
                armed: u64(PageLayout.killModeArmed) == 1,
                armingEpisodes: i64(PageLayout.killModeArmingEpisodes),
                reason: vocabulary(PageLayout.killModeReason, PageLayout.killModeReasonCodes, unknown: .unknown)),
            recommendation: NodeBudget.Recommendation(
                safeAdditionalBytes: opt(PageLayout.safeAdditionalBytes),
                basis: try structural(PageLayout.recommendationBasis, PageLayout.signalCodes)),
            counters: counters)
    }
}
