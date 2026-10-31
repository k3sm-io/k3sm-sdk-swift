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
internal import CK3smPage

/// A read-only mapping of the node budget page.
///
/// `open(path:)` maps the page and checks its header; `read()` checks the
/// header again and copies the body under the writer's seqlock. A writer
/// that takes the page over rewrites the header in place, so the ABI minor
/// can change under an open page and every read decodes by the header it
/// sees. The read path reads no environment and allocates only the
/// snapshot's node name and arrays. A page is never renamed or truncated by
/// its writer, so the mapping stays valid for the life of the object.
public final class BudgetPage: @unchecked Sendable {
    // @unchecked: the mapping is immutable after init and only ever read,
    // through C11 atomic loads, so sharing the object across threads is safe.

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
    /// The page's header size in bytes.
    public let headerSize: UInt32
    /// The ABI minor the page's header holds now. A higher minor than this
    /// SDK knows is read up to the fields this SDK knows.
    public var abiMinor: UInt16 { Self.loadHeader(base).minor }
    /// The body size the page's header holds now, in bytes: the region the
    /// seqlock covers.
    public var bodySize: UInt32 { Self.loadHeader(base).body }

    /// The start of the mapping; the notifier waits on a word of it.
    let base: UnsafeRawPointer
    private let length: Int

    private init(path: String, base: UnsafeRawPointer, length: Int) {
        self.path = path
        self.base = base
        self.length = length
        abiMajor = PageLayout.abiMajor
        headerSize = UInt32(PageLayout.headerSize)
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
        let page = BudgetPage(path: path, base: UnsafeRawPointer(m), length: length)
        // On a failure the page deinitializes and unmaps.
        _ = try page.loadCheckedHeader()
        return page
    }

    /// The three words of the header line: the magic, the word holding the
    /// major, the minor and the header size, and the word holding the body
    /// size. A writer stores each with one 8-byte store.
    private struct Header: Equatable {
        var magic: UInt64
        var versions: UInt64
        var sizes: UInt64

        var major: UInt16 { UInt16(truncatingIfNeeded: versions) }
        var minor: UInt16 { UInt16(truncatingIfNeeded: versions >> 16) }
        var header: UInt32 { UInt32(truncatingIfNeeded: versions >> 32) }
        var body: UInt32 { UInt32(truncatingIfNeeded: sizes) }
    }

    private static let magicWord: UInt64 = PageLayout.magic.reversed().reduce(0) { $0 << 8 | UInt64($1) }

    /// Loads the header line: the magic, the versions word, then the sizes
    /// word. `betweenLoads` runs between the last two loads; tests script a
    /// writer's resume through it.
    private static func loadHeader(_ base: UnsafeRawPointer, betweenLoads: () -> Void = {}) -> Header {
        let magic = ck3sm_page_load_relaxed(base, 0)
        let versions = ck3sm_page_load_relaxed(base, PageLayout.abiMajorOffset)
        betweenLoads()
        let sizes = ck3sm_page_load_relaxed(base, PageLayout.bodySizeOffset)
        return Header(magic: magic, versions: versions, sizes: sizes)
    }

    /// The header checks, in the contract's order.
    private func check(_ h: Header) throws(BudgetError) {
        guard h.magic == Self.magicWord, h.major == PageLayout.abiMajor, h.header == PageLayout.headerSize else {
            throw .abiMismatch
        }
        guard Int(h.body) >= PageLayout.requiredBodySize(minor: h.minor), length >= Int(h.header) + Int(h.body) else {
            throw .truncated
        }
    }

    /// Loads and checks the header line, loading it again while a check
    /// fails, up to `PageLayout.headerRetries` times; then the last check's
    /// error is the page's.
    private func loadCheckedHeader(betweenLoads: () -> Void = {}) throws(BudgetError) -> Header {
        var last = BudgetError.abiMismatch
        for _ in 0..<PageLayout.headerRetries {
            let h = Self.loadHeader(base, betweenLoads: betweenLoads)
            do throws(BudgetError) {
                try check(h)
                return h
            } catch {
                last = error
            }
        }
        throw last
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

    /// The seqlock read, through the C11 primitives of CK3smPage: seq loaded
    /// acquiring (odd: the writer is mid-write, try again), the header line
    /// loaded and checked (loaded again while a check fails, a bounded
    /// number of times), the body words of the header's minor loaded
    /// relaxed into a local copy, an acquiring fence, then seq and the
    /// header reloaded relaxed and compared. A header that changed during
    /// the attempt retries it, so the body is always decoded by the header
    /// it was copied under. After `PageLayout.readerRetries` attempts the
    /// read is torn. `afterAttempt` runs after each attempt's loads and
    /// before its fence and second loads, with the attempt number; tests
    /// script a writer through it.
    func read(now: Int64, afterAttempt: (Int) -> Void) -> Result<BudgetSnapshot, BudgetError> {
        read(now: now, afterAttempt: afterAttempt, betweenHeaderLoads: {})
    }

    /// The seqlock read with `betweenHeaderLoads` run between the loads of
    /// the versions word and the sizes word of every header load, for a
    /// test that scripts a resume there.
    func read(
        now: Int64, afterAttempt: (Int) -> Void, betweenHeaderLoads: () -> Void
    ) -> Result<BudgetSnapshot, BudgetError> {
        withUnsafeTemporaryAllocation(of: UInt64.self, capacity: PageLayout.bodyWords) { buf in
            for attempt in 0..<PageLayout.readerRetries {
                let s1 = ck3sm_page_load_acquire(base, PageLayout.seq)
                if s1 & 1 == 1 {
                    afterAttempt(attempt)
                    continue
                }
                let h1: Header
                do throws(BudgetError) {
                    h1 = try loadCheckedHeader(betweenLoads: betweenHeaderLoads)
                } catch {
                    return .failure(error)
                }
                // Only the words of the page's own minor are covered by its
                // seqlock; a minor-0 page's body ends before the minor-1
                // fields.
                let words = PageLayout.requiredBodySize(minor: h1.minor) / 8
                ck3sm_page_load_words_relaxed(base, PageLayout.headerSize, buf.baseAddress, words)
                afterAttempt(attempt)
                ck3sm_page_fence_acquire()
                let s2 = ck3sm_page_load_relaxed(base, PageLayout.seq)
                guard s1 == s2, Self.loadHeader(base) == h1 else { continue }
                let epoch = ck3sm_page_load_relaxed(base, PageLayout.notifyEpoch)
                return PageDecoder(words: UnsafeBufferPointer(rebasing: buf[0..<words]), minor: h1.minor)
                    .snapshot(seq: s1, notifyEpoch: epoch, now: now)
            }
            return .failure(.torn)
        }
    }
}

/// Decodes a stable copy of the body words. Offsets are page offsets.
private struct PageDecoder {
    let words: UnsafeBufferPointer<UInt64>
    /// The page's ABI minor: the fields of a later minor read as nil.
    let minor: UInt16

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
        var capacity = NodeBudget.Capacity(
            cpuCapacityMilli: opt(c), cpuSystemReserveMilli: opt(c + 8), memCapacityBytes: opt(c + 16),
            memSystemReserveBytes: opt(c + 24), memEvictionReserveBytes: opt(c + 32),
            memAllocatableBytes: opt(c + 40), swapTotalBytes: opt(c + 48), swapUsedBytes: opt(c + 56))
        if minor >= 1 {
            capacity.cpuPerformanceCores = opt(PageLayout.cpuPerformanceCores)
            capacity.cpuEfficiencyCores = opt(PageLayout.cpuEfficiencyCores)
            switch opt(PageLayout.gpuPresent) {
            case nil: capacity.gpuPresent = nil
            case 0: capacity.gpuPresent = false
            case 1: capacity.gpuPresent = true
            default: throw .corrupt
            }
            capacity.gpuCount = opt(PageLayout.gpuCount)
        }

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
