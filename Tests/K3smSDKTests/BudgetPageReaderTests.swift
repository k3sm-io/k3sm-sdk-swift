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

// The page fixtures are vendored byte for byte from apis@27bfab5
// budget/v1alpha1/testdata/page and checked against their SHA256SUMS by
// hack/verify-fixtures.sh. manifest.json and layout.v1.0.txt are the
// authority for every constant and offset below.

// MARK: - fixtures

private let pageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Fixtures/page")
private let statusDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Fixtures/nodebudget")

private func fixturePath(_ name: String) -> String { pageDir.appendingPathComponent(name).path }

private func manifest() throws -> [String: Any] {
    let data = try Data(contentsOf: pageDir.appendingPathComponent("manifest.json"))
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func manifestInt(_ m: [String: Any], _ key: String) throws -> Int64 {
    try #require((m[key] as? NSNumber)?.int64Value, "manifest key \(key)")
}

private func statusGolden(_ name: String) throws -> NodeBudget {
    try NodeBudgetDecoder.decodeBudget(Data(contentsOf: statusDir.appendingPathComponent(name)))
}

/// The layout descriptor's field lines.
private func layoutLines() throws -> [PageLayout.Field] {
    let text = try String(contentsOf: pageDir.appendingPathComponent("layout.v1.0.txt"), encoding: .utf8)
    return try text.split(separator: "\n").filter { !$0.hasPrefix("#") }.map { line in
        let p = line.split(separator: " ").map(String.init)
        try #require(p.count == 6, "layout line: \(line)")
        return PageLayout.Field(
            offset: try #require(Int(p[0])), size: try #require(Int(p[1])), kind: p[2],
            absent: p[3] == "absent", enumName: p[4] == "-" ? nil : p[4], name: p[5])
    }
}

/// A page file the test owns, with a writable shared mapping of it standing
/// in for the writer.
private final class ScratchPage {
    let path: String
    let base: UnsafeMutableRawPointer
    private let fd: Int32

    init(copying fixture: String, edit: (UnsafeMutableRawPointer) -> Void = { _ in }) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("k3sm-sdk-page-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        path = dir.appendingPathComponent("budget.v1.page").path
        try FileManager.default.copyItem(atPath: fixturePath(fixture), toPath: path)
        fd = open(path, O_RDWR)
        guard fd >= 0, let m = mmap(nil, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0), m != MAP_FAILED else {
            throw POSIXError(.EIO)
        }
        base = m
        edit(base)
    }

    deinit {
        munmap(base, 4096)
        close(fd)
        try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
    }

    func word(_ offset: Int) -> UnsafeMutablePointer<Atomic<UInt64>> {
        (base + offset).assumingMemoryBound(to: Atomic<UInt64>.self)
    }

    func store(_ offset: Int, _ value: UInt64) { word(offset).pointee.store(value, ordering: .releasing) }
    func load(_ offset: Int) -> UInt64 { word(offset).pointee.load(ordering: .acquiring) }
}

// MARK: - the expected snapshots, from the status goldens

private func expectedSnapshot(_ nb: NodeBudget) throws -> BudgetSnapshot {
    let s = try #require(nb.status)
    let observed = try #require(s.observedAt).date.timeIntervalSince1970
    return BudgetSnapshot(
        seq: 0,
        notifyEpoch: 0,
        generation: try #require(s.producerGeneration),
        writerPeriodSeconds: 1,
        observedAt: Int64(observed),
        platform: try #require(s.platform),
        nodeName: try #require(nb.metadata?.name),
        capacity: s.capacity ?? NodeBudget.Capacity(),
        level: try #require(s.level),
        darwin: s.darwin,
        linux: s.linux,
        signals: s.signals ?? [],
        admit: s.admit ?? false,
        admitReasonSignal: s.admitReasonSignal,
        evictDeadline: s.evictDeadline.map { Int64($0.date.timeIntervalSince1970) },
        killMode: BudgetSnapshot.KillMode(
            mode: s.killMode?.mode, armed: s.killMode?.armed ?? false,
            armingEpisodes: Int64(s.killMode?.armingEpisodes ?? 0), reason: s.killMode?.reason),
        recommendation: s.recommendation ?? NodeBudget.Recommendation(),
        counters: (s.counters ?? []).map {
            BudgetSnapshot.BandCounters(
                band: $0.band, evictionsTotal: $0.evictionsTotal, oomKillsTotal: $0.oomKillsTotal,
                kernelKillsTotal: $0.kernelKillsTotal, restartsTotal: $0.restartsTotal,
                memHighEventsTotal: $0.memHighEventsTotal, tier1RefusedTotal: $0.tier1RefusedTotal)
        })
}

/// The snapshot each decodable fixture encodes, per its manifest description.
private func expectedFixtures() throws -> [String: BudgetSnapshot] {
    let darwin = try expectedSnapshot(statusGolden("darwin.golden.json"))
    let linuxGolden = try statusGolden("linux.golden.json")
    var guest = darwin
    guest.linux = linuxGolden.status?.linux
    var absent = darwin
    absent.capacity = NodeBudget.Capacity()
    absent.darwin = NodeBudget.DarwinSignals()
    absent.signals = []
    absent.counters = []
    absent.recommendation = NodeBudget.Recommendation()
    absent.admitReasonSignal = nil
    absent.evictDeadline = nil
    return [
        "darwin.v1.page": darwin,
        "linux-producer.v1.page": try expectedSnapshot(linuxGolden),
        "linux-guest.v1.page": guest,
        "absent.v1.page": absent,
    ]
}

/// Every i64 field of a snapshot by its layout name; nil for an absent one.
private func i64Fields(_ s: BudgetSnapshot) -> [String: Int64?] {
    var m: [String: Int64?] = [
        "generation": s.generation, "writerPeriodSeconds": s.writerPeriodSeconds, "observedAt": s.observedAt,
        "evictDeadline": s.evictDeadline, "killMode.armingEpisodes": s.killMode.armingEpisodes,
        "recommendation.safeAdditionalBytes": s.recommendation.safeAdditionalBytes,
    ]
    let c = s.capacity
    for (n, v) in zip(PageLayout.capacityNames, [
        c.cpuCapacityMilli, c.cpuSystemReserveMilli, c.memCapacityBytes, c.memSystemReserveBytes,
        c.memEvictionReserveBytes, c.memAllocatableBytes, c.swapTotalBytes, c.swapUsedBytes,
    ]) { m["capacity." + n] = v }
    let d = s.darwin
    for (n, v) in zip(PageLayout.darwinNames, [
        d?.vmPressureLevel, d?.memorystatusLevelPermille, d?.compressor?.bytesUsed, d?.compressor?.bytesStored,
        d?.compressor?.segmentLimitBytes, d?.swapinsTotal, d?.swapoutsTotal,
    ]) { m["darwin." + n] = v }
    let psi = s.linux?.psi
    for (r, res) in zip(PageLayout.psiResources, [psi?.cpu, psi?.memory, psi?.io]) {
        for (l, line) in zip(PageLayout.psiLines, [res?.some, res?.full]) {
            for (v, value) in zip(PageLayout.psiValues, [line?.avg10Permille, line?.avg60Permille, line?.totalUs]) {
                m["linux.psi.\(r).\(l).\(v)"] = value
            }
        }
    }
    let e = s.linux?.memoryEvents
    for (n, v) in zip(PageLayout.memoryEventNames, [e?.high, e?.max, e?.oom, e?.oomKill]) {
        m["linux.memoryEvents." + n] = v
    }
    for (i, g) in s.signals.enumerated() {
        for (n, v) in zip(PageLayout.signalWordNames.dropFirst(2), [
            g.value, g.warnThreshold, g.admitStopThreshold, g.criticalThreshold, g.evictSoftThreshold,
            g.evictHardThreshold, g.warnRelease, g.admitStopRelease, g.criticalRelease, g.evictSoftRelease,
            g.evictHardRelease, g.graceSeconds, g.minReclaimBytes, g.windowSeconds, g.etaToNextRungSeconds,
        ]) { m["signals[\(i)].\(n)"] = v }
    }
    for (i, k) in s.counters.enumerated() {
        for (n, v) in zip(PageLayout.counterWordNames.dropFirst(), [
            k.evictionsTotal, k.oomKillsTotal, k.kernelKillsTotal, k.restartsTotal, k.memHighEventsTotal,
            k.tier1RefusedTotal,
        ]) { m["counters[\(i)].\(n)"] = v }
    }
    return m
}

private func readFixture(_ name: String, now: Int64? = nil) throws -> Result<BudgetSnapshot, BudgetError> {
    let page = try BudgetPage.open(path: fixturePath(name))
    let observedAt = try expectedFixtures()["darwin.v1.page"]!.observedAt
    return page.read(now: now ?? observedAt)
}

// MARK: - tests

@Suite struct BudgetPageReaderTests {
    @Test func readerConstantsMatchManifest() throws {
        let m = try manifest()
        #expect(try manifestInt(m, "pageABIMajor") == Int64(K3smSDKVersion.pageABIMajor))
        #expect(try manifestInt(m, "pageABIMajor") == Int64(PageLayout.abiMajor))
        #expect(try manifestInt(m, "pageABIMinor") == Int64(PageLayout.abiMinor))
        #expect(try manifestInt(m, "pageSize") == Int64(PageLayout.pageSize))
        #expect(try manifestInt(m, "headerSize") == Int64(PageLayout.headerSize))
        #expect(try manifestInt(m, "bodySize") == Int64(PageLayout.knownBodySize))
        #expect(try manifestInt(m, "absent") == PageLayout.absent)
        #expect(try manifestInt(m, "seqOffset") == Int64(PageLayout.seq))
        #expect(try manifestInt(m, "notifyEpochOffset") == Int64(PageLayout.notifyEpoch))
        #expect(try manifestInt(m, "maxNodeNameBytes") == Int64(PageLayout.maxNodeNameBytes))
        #expect(try manifestInt(m, "staleFactor") == PageLayout.staleFactor)
        #expect(try manifestInt(m, "readerRetries") == Int64(PageLayout.readerRetries))
        #expect(m["observedAtResolution"] as? String == "1s")
        #expect(m["magic"] as? String == String(decoding: PageLayout.magic, as: UTF8.self))
        #expect(m["defaultPagePath"] as? String == BudgetPage.darwinPagePath)
        #expect(m["linuxPagePath"] as? String == BudgetPage.linuxPagePath)
        #expect(BudgetPage.defaultPagePath == BudgetPage.darwinPagePath)
        #expect(m["nodeBudgetAPIVersion"] as? String == K3smSDKVersion.nodeBudgetAPIVersion)

        let codes = try #require(m["codes"] as? [String: [String]])
        let mine: [String: [String]] = [
            "signal": PageLayout.signalCodes.map(\.rawValue),
            "unit": PageLayout.unitCodes.map(\.rawValue),
            "level": PageLayout.levelCodes.map(\.rawValue),
            "band": PageLayout.bandCodes.map(\.rawValue),
            "platform": PageLayout.platformCodes.map(\.rawValue),
            "killMode": PageLayout.killModeCodes.map(\.rawValue),
            "trend": PageLayout.trendCodes.map(\.rawValue),
            "limitingResource": PageLayout.limitingResourceCodes.map(\.rawValue),
            "killModeReason": PageLayout.killModeReasonCodes.map(\.rawValue),
        ]
        #expect(codes == mine)

        let errors: [BudgetError] = [.notFound(errno: ENOENT), .abiMismatch, .truncated, .corrupt, .torn, .stale]
        let names = Set(errors.map(\.contractName))
        let negatives = try #require(m["negative"] as? [[String: Any]])
        for n in negatives {
            let e = try #require(n["error"] as? String)
            #expect(names.contains(e), "manifest error \(e) has no BudgetError case")
        }
    }

    @Test func layoutMatchesDescriptor() throws {
        let want = try layoutLines()
        let have = PageLayout.fields
        #expect(have.count == want.count)
        for (h, w) in zip(have, want) {
            #expect(h == w)
        }
        let end = try #require(want.last).offset + 8
        #expect(end == PageLayout.headerSize + PageLayout.knownBodySize)
    }

    /// The gate test: every decodable golden page reads to the snapshot its
    /// manifest entry describes, built from the status goldens it was
    /// encoded from.
    @Test func readerDecodesGoldenPageFixtures() throws {
        let m = try manifest()
        let fixtures = try #require(m["fixtures"] as? [[String: Any]])
        let expected = try expectedFixtures()
        var decoded = 0
        for f in fixtures {
            let file = try #require(f["file"] as? String)
            let decodes = try #require(f["decodes"] as? Bool)
            let page = try BudgetPage.open(path: fixturePath(file))
            #expect(page.abiMajor == 1)
            #expect(page.abiMinor == 0)
            #expect(page.headerSize == 192)
            #expect(page.bodySize == 2120)
            guard decodes else {
                #expect(throws: BudgetError.self) { try page.read(now: 0).get() }
                continue
            }
            let want = try #require(expected[file], "no expectation for the manifest fixture \(file)")
            let got = try page.read(now: want.observedAt).get()
            #expect(got == want, "\(file)")
            decoded += 1
        }
        #expect(decoded == expected.count)
    }

    /// Every i64 field at its layout offset: the pattern page holds
    /// 0x50415454 << 32 | offset in each word. Its codes and node name are
    /// patched to decodable values first.
    @Test func readerReadsEveryWordAtItsLayoutOffset() throws {
        let layout = try layoutLines()
        let pattern: (Int) -> UInt64 = { 0x5041_5454_0000_0000 | UInt64($0) }
        let page = try ScratchPage(copying: "pattern.v1.page") { base in
            for f in layout where f.enumName != nil {
                base.storeBytes(of: UInt64(1).littleEndian, toByteOffset: f.offset, as: UInt64.self)
            }
            base.storeBytes(of: UInt64(0), toByteOffset: PageLayout.nodeNameLen, as: UInt64.self)
            base.storeBytes(of: UInt64(1).littleEndian, toByteOffset: PageLayout.writerPeriodSeconds, as: UInt64.self)
        }
        let s = try BudgetPage.open(path: page.path).read(now: Int64(pattern(PageLayout.observedAt))).get()
        #expect(s.seq == pattern(PageLayout.seq))
        #expect(s.notifyEpoch == pattern(PageLayout.notifyEpoch))
        #expect(s.nodeName == "")
        #expect(s.signals.count == PageLayout.signalSlots)
        #expect(s.counters.count == PageLayout.counterSlots)
        let fields = i64Fields(s)
        var checked = 0
        for f in layout where f.kind == "i64" && f.name != "writerPeriodSeconds" {
            let v = try #require(fields[f.name], "no snapshot field for \(f.name)")
            #expect(v == Int64(bitPattern: pattern(f.offset)), "\(f.name) at \(f.offset)")
            checked += 1
        }
        #expect(checked == layout.filter { $0.kind == "i64" }.count - 1)
    }

    @Test func negativePagesGiveManifestErrors() throws {
        let negatives = try #require(try manifest()["negative"] as? [[String: Any]])
        #expect(negatives.count == 6)
        for n in negatives {
            let file = try #require(n["file"] as? String)
            let want = try #require(n["error"] as? String)
            var got: BudgetError?
            do {
                if case let .failure(e) = try readFixture(file) { got = e }
            } catch let e as BudgetError {
                got = e
            }
            #expect(got?.contractName == want, "\(file)")
        }
    }

    @Test func notFoundCarriesErrno() {
        #expect(throws: BudgetError.notFound(errno: ENOENT)) {
            try BudgetPage.open(path: pageDir.appendingPathComponent("no-such.v1.page").path)
        }
    }

    @Test func staleAfterThreeWriterPeriods() throws {
        let observedAt = try #require(try expectedFixtures()["darwin.v1.page"]).observedAt
        #expect(try readFixture("darwin.v1.page", now: observedAt + 3).get().observedAt == observedAt)
        #expect(try readFixture("darwin.v1.page", now: observedAt - 60).get().observedAt == observedAt)
        #expect(throws: BudgetError.stale) { try readFixture("darwin.v1.page", now: observedAt + 4).get() }
        #expect(throws: BudgetError.stale) { try readFixture("darwin.v1.page", now: Int64.max).get() }
    }

    /// A scripted writer keeps the seqlock busy through the reader's hook.
    @Test func scriptedTornReadIsTorn() throws {
        let scratch = try ScratchPage(copying: "darwin.v1.page")
        let page = try BudgetPage.open(path: scratch.path)
        let now = try #require(try expectedFixtures()["darwin.v1.page"]).observedAt

        // A writer that publishes during every attempt: torn after the bound.
        var attempts = 0
        let torn = page.read(now: now) { _ in
            attempts += 1
            scratch.store(PageLayout.seq, scratch.load(PageLayout.seq) + 2)
        }
        #expect(throws: BudgetError.torn) { try torn.get() }
        #expect(attempts == PageLayout.readerRetries)

        // A writer stuck mid-write (odd seq): torn after the bound.
        scratch.store(PageLayout.seq, scratch.load(PageLayout.seq) + 1)
        attempts = 0
        #expect(throws: BudgetError.torn) { try page.read(now: now) { _ in attempts += 1 }.get() }
        #expect(attempts == PageLayout.readerRetries)

        // The writer finishes on the third attempt and changes a value: the
        // read retries and returns the published value with the even seq.
        let level = PageLayout.level
        let s = try page.read(now: now) { attempt in
            if attempt == 2 {
                scratch.store(level, 3) // critical
                scratch.store(PageLayout.seq, scratch.load(PageLayout.seq) + 1)
            }
        }.get()
        #expect(s.level == .critical)
        #expect(s.seq == scratch.load(PageLayout.seq))
        #expect(s.seq % 2 == 0)

        // A torn attempt never leaks: the value stored mid-attempt with a
        // seq bump is only seen by the next attempt.
        var seen: [Int] = []
        let t = try page.read(now: now) { attempt in
            seen.append(attempt)
            if attempt == 0 {
                scratch.store(level, 4) // evicting, under a new seq
                scratch.store(PageLayout.seq, scratch.load(PageLayout.seq) + 2)
            }
        }.get()
        #expect(seen == [0, 1])
        #expect(t.level == .evicting)
    }

    @Test func helpersFollowTheSnapshot() throws {
        var s = try readFixture("darwin.v1.page").get()
        #expect(s.admitOK)
        // memory.available falls toward its rungs: 6 GiB now, warn at 2 GiB.
        #expect(s.bytesUntil(signal: .memoryAvailable, rung: .warn) == Int64(4) << 30)
        #expect(s.bytesUntil(signal: .memoryAvailable, rung: .evictHard) == Int64(6_442_450_944 - 104_857_600))
        // memory.compressor rises toward its rungs: 210 permille now, warn at 500.
        #expect(s.bytesUntil(signal: .memoryCompressor, rung: .warn) == Int64(290))
        // swapfs.available has no evict-soft rung; imagefs.available has no rungs.
        #expect(s.bytesUntil(signal: .swapfsAvailable, rung: .evictSoft) == nil)
        #expect(s.bytesUntil(signal: .imagefsAvailable, rung: .warn) == nil)
        // 3 GiB to spare.
        #expect(s.batchSlots(slotBytes: 1 << 30) == Int64(3))
        #expect(s.batchSlots(slotBytes: 2 << 30) == Int64(1))
        #expect(s.batchSlots(slotBytes: 0) == nil)

        s.signals[0].value = 1 << 30 // past warn and admit-stop
        #expect(s.bytesUntil(signal: .memoryAvailable, rung: .warn) == Int64(0))
        s.admit = false
        #expect(!s.admitOK)
        #expect(s.batchSlots(slotBytes: 1024) == Int64(0))
        s.recommendation.safeAdditionalBytes = nil
        #expect(s.batchSlots(slotBytes: 1024) == nil)

        let linux = try readFixture("linux-producer.v1.page").get()
        #expect(linux.bytesUntil(signal: .memoryCompressor, rung: .warn) == nil)
    }
}
