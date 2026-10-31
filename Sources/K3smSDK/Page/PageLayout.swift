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

#if _endian(big)
#error("the budget page is little-endian; a big-endian host cannot read it")
#endif

/// The page ABI this reader knows: major 1, minor 1. Every offset is a byte
/// offset from the start of the page file. The apis layout descriptors
/// (layout.v1.0.txt, layout.v1.1.txt) are the authority; a test checks
/// `fields` against them line for line. A minor only appends fields, so the
/// minor-0 layout is a prefix of the minor-1 layout.
enum PageLayout {
    static let abiMajor: UInt16 = 1
    static let abiMinor: UInt16 = 1
    static let pageSize = 4096
    static let headerSize = 192
    /// The body size of the known minor: a page of a higher minor is read up
    /// to here and no further.
    static let knownBodySize = 2152
    /// The body size of minor 0, the smallest body a page of this major has.
    /// A minor-0 page carries none of the minor-1 fields.
    static let minor0BodySize = 2120
    static let bodyWords = knownBodySize / 8
    static let magic: [UInt8] = Array("K3SMBDGT".utf8)
    static let absent = Int64.min
    static let maxNodeNameBytes = 253
    static let nodeNameBytes = 256
    /// A page is stale when now - observedAt exceeds this many writer periods.
    static let staleFactor: Int64 = 3
    /// The number of read attempts before a read is torn.
    static let readerRetries = 64
    /// The number of times a read loads the header line before it reports
    /// the page truncated or of another ABI. A writer taking the page over
    /// rewrites the minor word and the body size word with two stores, in
    /// an order that keeps every header it leaves valid; a reader loads
    /// them with two loads, so it can pair the old minor with the new body
    /// size, and a reload sees a header the writer stored.
    static let headerRetries = 64

    // Header line.
    static let abiMajorOffset = 8
    static let abiMinorOffset = 10
    static let headerSizeOffset = 12
    static let bodySizeOffset = 16
    static let seq = 64
    static let notifyEpoch = 128

    // Body.
    static let generation = 192
    static let writerPeriodSeconds = 200
    static let observedAt = 208
    static let platform = 216
    static let nodeNameLen = 224
    static let nodeName = 232
    static let capacity = 488
    static let capacityNames = [
        "cpuCapacityMilli", "cpuSystemReserveMilli", "memCapacityBytes", "memSystemReserveBytes",
        "memEvictionReserveBytes", "memAllocatableBytes", "swapTotalBytes", "swapUsedBytes",
    ]
    static let level = 552
    static let darwin = 560
    static let darwinNames = [
        "vmPressureLevel", "memorystatusLevelPermille", "compressor.bytesUsed", "compressor.bytesStored",
        "compressor.segmentLimitBytes", "swapinsTotal", "swapoutsTotal",
    ]
    static let linuxPSI = 616
    static let psiResources = ["cpu", "memory", "io"]
    static let psiLines = ["some", "full"]
    static let psiValues = ["avg10Permille", "avg60Permille", "totalUs"]
    static let linuxMemoryEvents = 760
    static let memoryEventNames = ["high", "max", "oom", "oomKill"]
    static let signals = 792
    static let signalSlots = 8
    static let signalStride = 160
    /// The words of one signal slot, in order. The ten ladder words follow
    /// `value`: five rungs, then five release values.
    static let signalWordNames = [
        "id", "unit", "value",
        "warnThreshold", "admitStopThreshold", "criticalThreshold", "evictSoftThreshold", "evictHardThreshold",
        "warnRelease", "admitStopRelease", "criticalRelease", "evictSoftRelease", "evictHardRelease",
        "graceSeconds", "minReclaimBytes", "windowSeconds", "etaToNextRungSeconds",
        "trend", "limitingResource", "sharedWith",
    ]
    static let admit = 2072
    static let admitReasonSignal = 2080
    static let evictDeadline = 2088
    static let killModeMode = 2096
    static let killModeArmed = 2104
    static let killModeArmingEpisodes = 2112
    static let killModeReason = 2120
    static let safeAdditionalBytes = 2128
    static let recommendationBasis = 2136
    static let counters = 2144
    static let counterSlots = 3
    static let counterStride = 56
    static let counterWordNames = [
        "band", "evictionsTotal", "oomKillsTotal", "kernelKillsTotal", "restartsTotal",
        "memHighEventsTotal", "tier1RefusedTotal",
    ]
    // Minor 1: the CPU core split and the GPU presence, after the counters.
    // gpuPresent is an i64 holding 0 or 1, or the absent sentinel.
    static let cpuPerformanceCores = 2312
    static let cpuEfficiencyCores = 2320
    static let gpuPresent = 2328
    static let gpuCount = 2336

    /// The body size a page of `minor` must carry: the end of the last field
    /// of that minor, or of the known minor when the page's is higher.
    static func requiredBodySize(minor: UInt16) -> Int {
        minor >= 1 ? knownBodySize : minor0BodySize
    }

    /// The code tables: the value at index i has code i + 1, and code 0 is
    /// unset. The order is the apis manifest's.
    static let signalCodes = NodeBudget.SignalID.knownValues
    static let unitCodes: [NodeBudget.SignalUnit] = [.bytes, .permille, .count]
    static let levelCodes: [NodeBudget.Level] = [.ok, .warn, .critical, .evicting]
    static let bandCodes: [NodeBudget.Band] = [.critical, .standard, .batch]
    static let platformCodes: [NodeBudget.Platform] = [.darwin, .linux]
    static let killModeCodes: [NodeBudget.KillModeName] = [.auto, .on, .off]
    static let trendCodes: [NodeBudget.Trend] = [.falling, .steady, .rising]
    static let limitingResourceCodes: [NodeBudget.LimitingResource] = [
        .memory, .swapfs, .nodefs, .imagefs, .pid, .cpu,
    ]
    static let killModeReasonCodes: [NodeBudget.KillModeReason] = [
        .coldStart, .observing, .armed, .policyOff, .disarmFile,
    ]

    /// One line of the layout descriptor.
    struct Field: Equatable {
        var offset: Int
        var size: Int
        var kind: String
        var absent: Bool
        var enumName: String?
        var name: String
    }

    /// The layout as this reader knows it, built from the offsets above, in
    /// offset order.
    static var fields: [Field] {
        var f: [Field] = []
        func add(_ offset: Int, _ size: Int, _ kind: String, _ absent: Bool, _ e: String?, _ name: String) {
            f.append(Field(offset: offset, size: size, kind: kind, absent: absent, enumName: e, name: name))
        }
        add(0, 8, "bytes", false, nil, "magic")
        add(abiMajorOffset, 2, "u16", false, nil, "abiMajor")
        add(abiMinorOffset, 2, "u16", false, nil, "abiMinor")
        add(headerSizeOffset, 4, "u32", false, nil, "headerSize")
        add(bodySizeOffset, 4, "u32", false, nil, "bodySize")
        add(seq, 8, "u64", false, nil, "seq")
        add(notifyEpoch, 8, "u64", false, nil, "notifyEpoch")
        add(generation, 8, "i64", false, nil, "generation")
        add(writerPeriodSeconds, 8, "i64", false, nil, "writerPeriodSeconds")
        add(observedAt, 8, "i64", false, nil, "observedAt")
        add(platform, 8, "u64", false, "platform", "platform")
        add(nodeNameLen, 8, "u64", false, nil, "nodeNameLen")
        add(nodeName, nodeNameBytes, "bytes", false, nil, "nodeName")
        for (i, n) in capacityNames.enumerated() {
            add(capacity + 8 * i, 8, "i64", true, nil, "capacity." + n)
        }
        add(level, 8, "u64", false, "level", "level")
        for (i, n) in darwinNames.enumerated() {
            add(darwin + 8 * i, 8, "i64", true, nil, "darwin." + n)
        }
        var off = linuxPSI
        for r in psiResources {
            for l in psiLines {
                for v in psiValues {
                    add(off, 8, "i64", true, nil, "linux.psi.\(r).\(l).\(v)")
                    off += 8
                }
            }
        }
        for (i, n) in memoryEventNames.enumerated() {
            add(linuxMemoryEvents + 8 * i, 8, "i64", true, nil, "linux.memoryEvents." + n)
        }
        let signalEnums: [String: String] = [
            "id": "signal", "unit": "unit", "trend": "trend", "limitingResource": "limitingResource",
            "sharedWith": "signal",
        ]
        for s in 0..<signalSlots {
            for (i, n) in signalWordNames.enumerated() {
                let e = signalEnums[n]
                add(signals + s * signalStride + 8 * i, 8, e == nil ? "i64" : "u64", e == nil, e, "signals[\(s)].\(n)")
            }
        }
        add(admit, 8, "u64", false, "bool", "admit")
        add(admitReasonSignal, 8, "u64", false, "signal", "admitReasonSignal")
        add(evictDeadline, 8, "i64", true, nil, "evictDeadline")
        add(killModeMode, 8, "u64", false, "killMode", "killMode.mode")
        add(killModeArmed, 8, "u64", false, "bool", "killMode.armed")
        add(killModeArmingEpisodes, 8, "i64", false, nil, "killMode.armingEpisodes")
        add(killModeReason, 8, "u64", false, "killModeReason", "killMode.reason")
        add(safeAdditionalBytes, 8, "i64", true, nil, "recommendation.safeAdditionalBytes")
        add(recommendationBasis, 8, "u64", false, "signal", "recommendation.basis")
        for c in 0..<counterSlots {
            for (i, n) in counterWordNames.enumerated() {
                let isBand = i == 0
                add(counters + c * counterStride + 8 * i, 8, isBand ? "u64" : "i64", false, isBand ? "band" : nil,
                    "counters[\(c)].\(n)")
            }
        }
        add(cpuPerformanceCores, 8, "i64", true, nil, "capacity.cpuPerformanceCores")
        add(cpuEfficiencyCores, 8, "i64", true, nil, "capacity.cpuEfficiencyCores")
        add(gpuPresent, 8, "i64", true, "bool", "capacity.gpuPresent")
        add(gpuCount, 8, "i64", true, nil, "capacity.gpuCount")
        return f
    }
}
