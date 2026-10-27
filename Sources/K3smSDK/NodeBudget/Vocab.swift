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

/// A string-valued vocabulary of the NodeBudget wire format. Each type is
/// open: a value the SDK does not know decodes, keeps its spelling and
/// re-encodes unchanged, so a newer producer never breaks an older reader.
/// `isKnown` tells a known value from a newer one.
public protocol NodeBudgetVocabulary: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible
where RawValue == String {
    /// The values this version of the SDK knows.
    static var knownValues: [Self] { get }
    /// Wraps any string, known or not.
    init(rawValue: String)
}

extension NodeBudgetVocabulary {
    /// Whether this version of the SDK knows the value.
    public var isKnown: Bool { Self.knownValues.contains(self) }
    /// The wire spelling.
    public var description: String { rawValue }
}

extension NodeBudget {
    /// A signal's identifier: the threshold-ladder signal a record reports.
    public struct SignalID: NodeBudgetVocabulary {
        /// The wire spelling.
        public let rawValue: String
        /// Wraps any string, known or not.
        public init(rawValue: String) { self.rawValue = rawValue }
        /// Available memory, in bytes.
        public static let memoryAvailable = SignalID(rawValue: "memory.available")
        /// Compressor occupancy, in permille.
        public static let memoryCompressor = SignalID(rawValue: "memory.compressor")
        /// Swap growth, in bytes over the record's windowSeconds.
        public static let memorySwap = SignalID(rawValue: "memory.swap")
        /// Free space on the swap filesystem, in bytes.
        public static let swapfsAvailable = SignalID(rawValue: "swapfs.available")
        /// Free space on the node filesystem, in bytes.
        public static let nodefsAvailable = SignalID(rawValue: "nodefs.available")
        /// Free space on the image filesystem, in bytes.
        public static let imagefsAvailable = SignalID(rawValue: "imagefs.available")
        /// Free process ids, as a count.
        public static let pidAvailable = SignalID(rawValue: "pid.available")
        /// The known signals, in their page-code order.
        public static let knownValues: [SignalID] = [
            .memoryAvailable, .memoryCompressor, .memorySwap, .swapfsAvailable,
            .nodefsAvailable, .imagefsAvailable, .pidAvailable,
        ]
    }

    /// The unit of a signal's value and thresholds.
    public struct SignalUnit: NodeBudgetVocabulary {
        /// The wire spelling.
        public let rawValue: String
        /// Wraps any string, known or not.
        public init(rawValue: String) { self.rawValue = rawValue }
        /// Bytes.
        public static let bytes = SignalUnit(rawValue: "bytes")
        /// Parts per thousand.
        public static let permille = SignalUnit(rawValue: "permille")
        /// A plain count.
        public static let count = SignalUnit(rawValue: "count")
        /// The known units.
        public static let knownValues: [SignalUnit] = [.bytes, .permille, .count]
    }

    /// The node's pressure level.
    public struct Level: NodeBudgetVocabulary {
        /// The wire spelling.
        public let rawValue: String
        /// Wraps any string, known or not.
        public init(rawValue: String) { self.rawValue = rawValue }
        /// No signal is past its warn rung.
        public static let ok = Level(rawValue: "ok")
        /// A signal is past its warn rung.
        public static let warn = Level(rawValue: "warn")
        /// A signal is past its critical rung.
        public static let critical = Level(rawValue: "critical")
        /// The node is evicting.
        public static let evicting = Level(rawValue: "evicting")
        /// The known levels, least to most severe.
        public static let knownValues: [Level] = [.ok, .warn, .critical, .evicting]
    }

    /// A workload priority band.
    public struct Band: NodeBudgetVocabulary {
        /// The wire spelling.
        public let rawValue: String
        /// Wraps any string, known or not.
        public init(rawValue: String) { self.rawValue = rawValue }
        /// The critical band.
        public static let critical = Band(rawValue: "critical")
        /// The standard band.
        public static let standard = Band(rawValue: "standard")
        /// The batch band.
        public static let batch = Band(rawValue: "batch")
        /// The known bands.
        public static let knownValues: [Band] = [.critical, .standard, .batch]
    }

    /// The direction a signal is moving in.
    public struct Trend: NodeBudgetVocabulary {
        /// The wire spelling.
        public let rawValue: String
        /// Wraps any string, known or not.
        public init(rawValue: String) { self.rawValue = rawValue }
        /// Falling.
        public static let falling = Trend(rawValue: "falling")
        /// Steady.
        public static let steady = Trend(rawValue: "steady")
        /// Rising.
        public static let rising = Trend(rawValue: "rising")
        /// Not yet known.
        public static let unknown = Trend(rawValue: "unknown")
        /// The known trends.
        public static let knownValues: [Trend] = [.falling, .steady, .rising, .unknown]
    }

    /// The resource that limits a signal.
    public struct LimitingResource: NodeBudgetVocabulary {
        /// The wire spelling.
        public let rawValue: String
        /// Wraps any string, known or not.
        public init(rawValue: String) { self.rawValue = rawValue }
        /// Memory.
        public static let memory = LimitingResource(rawValue: "memory")
        /// The swap filesystem.
        public static let swapfs = LimitingResource(rawValue: "swapfs")
        /// The node filesystem.
        public static let nodefs = LimitingResource(rawValue: "nodefs")
        /// The image filesystem.
        public static let imagefs = LimitingResource(rawValue: "imagefs")
        /// Process ids.
        public static let pid = LimitingResource(rawValue: "pid")
        /// CPU.
        public static let cpu = LimitingResource(rawValue: "cpu")
        /// Not known.
        public static let unknown = LimitingResource(rawValue: "unknown")
        /// The known resources.
        public static let knownValues: [LimitingResource] = [
            .memory, .swapfs, .nodefs, .imagefs, .pid, .cpu, .unknown,
        ]
    }

    /// The configured kill mode.
    public struct KillModeName: NodeBudgetVocabulary {
        /// The wire spelling.
        public let rawValue: String
        /// Wraps any string, known or not.
        public init(rawValue: String) { self.rawValue = rawValue }
        /// Arms itself after observing the node.
        public static let auto = KillModeName(rawValue: "auto")
        /// Always armed.
        public static let on = KillModeName(rawValue: "on")
        /// Never armed.
        public static let off = KillModeName(rawValue: "off")
        /// The known modes.
        public static let knownValues: [KillModeName] = [.auto, .on, .off]
    }

    /// Why the kill mode is armed or not.
    public struct KillModeReason: NodeBudgetVocabulary {
        /// The wire spelling.
        public let rawValue: String
        /// Wraps any string, known or not.
        public init(rawValue: String) { self.rawValue = rawValue }
        /// The node has no valid policy yet, and observes.
        public static let coldStart = KillModeReason(rawValue: "cold-start")
        /// The node is still observing.
        public static let observing = KillModeReason(rawValue: "observing")
        /// The kill mode is armed.
        public static let armed = KillModeReason(rawValue: "armed")
        /// A policy turned it off.
        public static let policyOff = KillModeReason(rawValue: "policy-off")
        /// A disarm file turned it off.
        public static let disarmFile = KillModeReason(rawValue: "disarm-file")
        /// Not known.
        public static let unknown = KillModeReason(rawValue: "unknown")
        /// The known reasons.
        public static let knownValues: [KillModeReason] = [
            .coldStart, .observing, .armed, .policyOff, .disarmFile, .unknown,
        ]
    }

    /// Why the node would kill a band.
    public struct WouldKillReason: NodeBudgetVocabulary {
        /// The wire spelling.
        public let rawValue: String
        /// Wraps any string, known or not.
        public init(rawValue: String) { self.rawValue = rawValue }
        /// Pressure has been held past its grace.
        public static let heldPressure = WouldKillReason(rawValue: "held-pressure")
        /// Memory is below its floor.
        public static let memoryFloor = WouldKillReason(rawValue: "memory-floor")
        /// Not known.
        public static let unknown = WouldKillReason(rawValue: "unknown")
        /// The known reasons.
        public static let knownValues: [WouldKillReason] = [.heldPressure, .memoryFloor, .unknown]
    }

    /// What became of the policy the node was given.
    public struct PolicyOutcome: NodeBudgetVocabulary {
        /// The wire spelling.
        public let rawValue: String
        /// Wraps any string, known or not.
        public init(rawValue: String) { self.rawValue = rawValue }
        /// Applied as written.
        public static let applied = PolicyOutcome(rawValue: "applied")
        /// Rejected.
        public static let rejected = PolicyOutcome(rawValue: "rejected")
        /// Applied with some fields clamped.
        public static let clamped = PolicyOutcome(rawValue: "clamped")
        /// The known outcomes.
        public static let knownValues: [PolicyOutcome] = [.applied, .rejected, .clamped]
    }

    /// A policy field the node may clamp.
    public struct PolicyField: NodeBudgetVocabulary {
        /// The wire spelling.
        public let rawValue: String
        /// Wraps any string, known or not.
        public init(rawValue: String) { self.rawValue = rawValue }
        /// tier1GraceSeconds.
        public static let tier1GraceSeconds = PolicyField(rawValue: "tier1GraceSeconds")
        /// tier1HeldSeconds.
        public static let tier1HeldSeconds = PolicyField(rawValue: "tier1HeldSeconds")
        /// tier1MaxDeliveriesPerHour.
        public static let tier1MaxDeliveriesPerHour = PolicyField(rawValue: "tier1MaxDeliveriesPerHour")
        /// tier1CooloffSeconds.
        public static let tier1CooloffSeconds = PolicyField(rawValue: "tier1CooloffSeconds")
        /// reserves.cpuSystemReserveMilli.
        public static let reservesCPUSystemReserveMilli = PolicyField(rawValue: "reserves.cpuSystemReserveMilli")
        /// reserves.memSystemReserveBytes.
        public static let reservesMemSystemReserveBytes = PolicyField(rawValue: "reserves.memSystemReserveBytes")
        /// reserves.memEvictionReserveBytes.
        public static let reservesMemEvictionReserveBytes = PolicyField(rawValue: "reserves.memEvictionReserveBytes")
        /// The known fields.
        public static let knownValues: [PolicyField] = [
            .tier1GraceSeconds, .tier1HeldSeconds, .tier1MaxDeliveriesPerHour, .tier1CooloffSeconds,
            .reservesCPUSystemReserveMilli, .reservesMemSystemReserveBytes, .reservesMemEvictionReserveBytes,
        ]
    }

    /// The window a windowed counter covers.
    public struct CounterWindow: NodeBudgetVocabulary {
        /// The wire spelling.
        public let rawValue: String
        /// Wraps any string, known or not.
        public init(rawValue: String) { self.rawValue = rawValue }
        /// The last hour.
        public static let oneHour = CounterWindow(rawValue: "1h")
        /// The last 24 hours.
        public static let oneDay = CounterWindow(rawValue: "24h")
        /// The known windows.
        public static let knownValues: [CounterWindow] = [.oneHour, .oneDay]
    }

    /// What a windowed counter counts.
    public struct CounterReason: NodeBudgetVocabulary {
        /// The wire spelling.
        public let rawValue: String
        /// Wraps any string, known or not.
        public init(rawValue: String) { self.rawValue = rawValue }
        /// Evictions.
        public static let eviction = CounterReason(rawValue: "eviction")
        /// Out-of-memory kills.
        public static let oomKill = CounterReason(rawValue: "oom-kill")
        /// Kills by the kernel.
        public static let kernelKill = CounterReason(rawValue: "kernel-kill")
        /// Restarts.
        public static let restart = CounterReason(rawValue: "restart")
        /// Memory-high events.
        public static let memHigh = CounterReason(rawValue: "mem-high")
        /// Refused first-tier deliveries.
        public static let tier1Refused = CounterReason(rawValue: "tier1-refused")
        /// Not known.
        public static let unknown = CounterReason(rawValue: "unknown")
        /// The known reasons.
        public static let knownValues: [CounterReason] = [
            .eviction, .oomKill, .kernelKill, .restart, .memHigh, .tier1Refused, .unknown,
        ]
    }

    /// How the status reached the API server.
    public struct WriterShape: NodeBudgetVocabulary {
        /// The wire spelling.
        public let rawValue: String
        /// Wraps any string, known or not.
        public init(rawValue: String) { self.rawValue = rawValue }
        /// Relayed from a node annotation by the control plane.
        public static let annotationRelay = WriterShape(rawValue: "annotation-relay")
        /// Written by the node itself.
        public static let ownNode = WriterShape(rawValue: "own-node")
        /// The known shapes.
        public static let knownValues: [WriterShape] = [.annotationRelay, .ownNode]
    }

    /// The node's platform.
    public struct Platform: NodeBudgetVocabulary {
        /// The wire spelling.
        public let rawValue: String
        /// Wraps any string, known or not.
        public init(rawValue: String) { self.rawValue = rawValue }
        /// macOS.
        public static let darwin = Platform(rawValue: "darwin")
        /// Linux.
        public static let linux = Platform(rawValue: "linux")
        /// The known platforms.
        public static let knownValues: [Platform] = [.darwin, .linux]
    }

    /// A condition's status.
    public struct ConditionStatus: NodeBudgetVocabulary {
        /// The wire spelling.
        public let rawValue: String
        /// Wraps any string, known or not.
        public init(rawValue: String) { self.rawValue = rawValue }
        /// The condition holds.
        public static let `true` = ConditionStatus(rawValue: "True")
        /// The condition does not hold.
        public static let `false` = ConditionStatus(rawValue: "False")
        /// Not known.
        public static let unknown = ConditionStatus(rawValue: "Unknown")
        /// The known statuses.
        public static let knownValues: [ConditionStatus] = [.true, .false, .unknown]
    }

    /// The condition types a NodeBudget status carries.
    public enum ConditionType {
        /// Whether the node's budget is current.
        public static let reporting = "Reporting"
        /// Whether the node rejected its policy.
        public static let policyRejected = "PolicyRejected"
        /// Whether the node clamped fields of its policy.
        public static let policyClamped = "PolicyClamped"
        /// Whether more than one policy selects the node.
        public static let policyConflict = "PolicyConflict"
    }

    /// The condition reasons a NodeBudget status carries.
    public enum ConditionReason {
        /// Reporting is True.
        public static let nodeReporting = "NodeReporting"
        /// Reporting is False: the node stopped reporting.
        public static let nodeNotReporting = "NodeNotReporting"
        /// Reporting is False: the node's annotation did not parse.
        public static let annotationMalformed = "AnnotationMalformed"
        /// Reporting is False: the node's schema is not supported.
        public static let schemaUnsupported = "SchemaUnsupported"
        /// Reporting is False: the node's annotation is too large.
        public static let annotationTooLarge = "AnnotationTooLarge"
        /// PolicyRejected is True: the policy is invalid.
        public static let policyInvalid = "PolicyInvalid"
        /// PolicyRejected is True: the merged threshold ladder is inverted.
        public static let mergedLadderInverted = "MergedLadderInverted"
        /// PolicyRejected is False.
        public static let policyAccepted = "PolicyAccepted"
        /// PolicyClamped is True.
        public static let fieldsClamped = "FieldsClamped"
        /// PolicyClamped is False.
        public static let noFieldsClamped = "NoFieldsClamped"
        /// PolicyConflict is True.
        public static let multiplePolicies = "MultiplePolicies"
        /// PolicyConflict is False.
        public static let singlePolicy = "SinglePolicy"
    }
}
