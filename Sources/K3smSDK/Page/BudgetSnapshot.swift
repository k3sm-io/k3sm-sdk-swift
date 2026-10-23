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

/// One stable read of the budget page: every body field of the layout, and
/// the seq and notifyEpoch words the read saw. Values mirror NodeBudget
/// status under the same names and units; an i64 the producer could not
/// sample (the absent sentinel, Int64.min) reads as nil. Times are whole
/// Unix seconds.
public struct BudgetSnapshot: Equatable, Sendable {
    /// The seqlock word of the stable read (even).
    public var seq: UInt64
    /// The notify word when the read completed. It changes on a change of
    /// level, admit, a threshold or the generation, and wraps: compare it for
    /// inequality only.
    public var notifyEpoch: UInt64
    /// The producer's generation, status.producerGeneration.
    public var generation: Int64
    /// The writer's publication period in seconds, at least 1.
    public var writerPeriodSeconds: Int64
    /// When the producer took the observation, in Unix seconds.
    public var observedAt: Int64
    /// The producer's platform.
    public var platform: NodeBudget.Platform
    /// The node's name, metadata.name.
    public var nodeName: String
    /// The node's capacity and reserves.
    public var capacity: NodeBudget.Capacity
    /// The derived pressure level.
    public var level: NodeBudget.Level
    /// The macOS platform block, present on a darwin page.
    public var darwin: NodeBudget.DarwinSignals?
    /// The Linux platform block: present on a linux page, and on a darwin
    /// page relayed into a vm guest (the guest section).
    public var linux: NodeBudget.LinuxSignals?
    /// The signal records, one per filled slot, in slot order.
    public var signals: [NodeBudget.Signal]
    /// Whether the node admits new work: every signal below its admit-stop rung.
    public var admit: Bool
    /// The signal that blocks admission, when one does.
    public var admitReasonSignal: NodeBudget.SignalID?
    /// When the evict-soft grace runs out, in Unix seconds.
    public var evictDeadline: Int64?
    /// The published tier-1 kill mode.
    public var killMode: KillMode
    /// How much more the node can safely take.
    public var recommendation: NodeBudget.Recommendation
    /// The per-band running totals, one per filled slot, in slot order.
    public var counters: [BandCounters]

    /// The tier-1 kill mode as the page carries it.
    public struct KillMode: Equatable, Sendable {
        /// The configured mode, nil when unset.
        public var mode: NodeBudget.KillModeName?
        /// Whether tier 1 is armed.
        public var armed: Bool
        /// The pressure episodes observed toward arming.
        public var armingEpisodes: Int64
        /// Why the mode is in its state, nil when unset; a reason this SDK
        /// does not know reads as `.unknown`.
        public var reason: NodeBudget.KillModeReason?
    }

    /// The running totals of one priority band. The page carries no windowed
    /// counts; those stay on the NodeBudget.
    public struct BandCounters: Equatable, Sendable {
        /// The band counted.
        public var band: NodeBudget.Band
        /// Evictions.
        public var evictionsTotal: Int64
        /// Out-of-memory kills.
        public var oomKillsTotal: Int64
        /// Kernel kills the producer did not initiate.
        public var kernelKillsTotal: Int64
        /// Container restarts.
        public var restartsTotal: Int64
        /// memory.high events.
        public var memHighEventsTotal: Int64
        /// Refused tier-1 deliveries.
        public var tier1RefusedTotal: Int64
    }

    /// A rung of a signal's threshold ladder, in escalating order.
    public enum Rung: Sendable, CaseIterable {
        /// The warn rung.
        case warn
        /// The admit-stop rung: at or past it the node refuses new work.
        case admitStop
        /// The critical rung.
        case critical
        /// The soft-eviction rung.
        case evictSoft
        /// The hard-eviction rung.
        case evictHard
    }

    // MARK: helpers

    /// Whether the node admits new work.
    public var admitOK: Bool { admit }

    /// How far the signal's value is from the rung, in the signal's unit
    /// (bytes, permille or a count): 0 when the value is at or past it, nil
    /// when the page has no such signal or the value or the rung is absent.
    /// The `available` signals reach a rung by falling, `memory.compressor`
    /// and `memory.swap` by rising.
    public func bytesUntil(signal: NodeBudget.SignalID, rung: Rung) -> Int64? {
        guard let s = signals.first(where: { $0.id == signal }), let value = s.value else { return nil }
        let threshold: Int64?
        switch rung {
        case .warn: threshold = s.warnThreshold
        case .admitStop: threshold = s.admitStopThreshold
        case .critical: threshold = s.criticalThreshold
        case .evictSoft: threshold = s.evictSoftThreshold
        case .evictHard: threshold = s.evictHardThreshold
        }
        guard let threshold else { return nil }
        let rising = signal == .memoryCompressor || signal == .memorySwap
        let (d, overflow) = rising
            ? threshold.subtractingReportingOverflow(value)
            : value.subtractingReportingOverflow(threshold)
        if overflow { return rising == (threshold > value) ? Int64.max : 0 }
        return max(0, d)
    }

    /// How many slots of `slotBytes` each the node can safely take now: 0
    /// while it does not admit, nil when the page carries no recommendation
    /// or `slotBytes` is not positive. A consumer may only lower its own cap
    /// with it.
    public func batchSlots(slotBytes: Int64) -> Int64? {
        guard slotBytes > 0, let safe = recommendation.safeAdditionalBytes else { return nil }
        guard admit else { return 0 }
        return max(0, safe) / slotBytes
    }
}
