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

/// The status of a NodeBudget: the node's latest observation, who wrote it,
/// and the conditions the control plane keeps on it. Every field is optional
/// because the producer omits empty ones.
public struct NodeBudgetStatus: Codable, Equatable, Sendable {
    /// When the node made the observation.
    public var observedAt: NodeBudget.Timestamp?
    /// The producer's generation, increasing with each observation.
    public var producerGeneration: Int64?
    /// The node's platform.
    public var platform: NodeBudget.Platform?
    /// The node's pressure level.
    public var level: NodeBudget.Level?
    /// Whether the node admits new pods.
    public var admit: Bool?
    /// The signal that stopped admission.
    public var admitReasonSignal: NodeBudget.SignalID?
    /// When eviction starts unless pressure eases.
    public var evictDeadline: NodeBudget.Timestamp?
    /// The node's capacity and reserves.
    public var capacity: NodeBudget.Capacity?
    /// One record per signal.
    public var signals: [NodeBudget.Signal]?
    /// How much more the node can take.
    public var recommendation: NodeBudget.Recommendation?
    /// The kill mode and whether it is armed.
    public var killMode: NodeBudget.KillMode?
    /// The last tier-1 kill decision, armed or observed: the band and the trigger.
    public var wouldKill: NodeBudget.WouldKill?
    /// Per-band counters.
    public var counters: [NodeBudget.BandCounters]?
    /// The policy the node applied, and the outcome.
    public var policy: NodeBudget.AppliedPolicy?
    /// The policy in force.
    public var inForce: NodeBudget.PolicyRef?
    /// The macOS signals.
    public var darwin: NodeBudget.DarwinSignals?
    /// The Linux signals.
    public var linux: NodeBudget.LinuxSignals?
    /// How the status reached the API server.
    public var writer: NodeBudget.Writer?
    /// The status conditions.
    public var conditions: [NodeBudget.Condition]?

    /// The wire keys.
    enum CodingKeys: String, CodingKey, CaseIterable {
        case observedAt, producerGeneration, platform, level, admit, admitReasonSignal, evictDeadline
        case capacity, signals, recommendation, killMode, wouldKill, counters, policy, inForce
        case darwin, linux, writer, conditions
    }
}

extension NodeBudget {
    /// The node's capacity and the reserves held back from workloads.
    public struct Capacity: Codable, Equatable, Sendable {
        /// CPU capacity, in millicores.
        public var cpuCapacityMilli: Int64?
        /// CPU reserved for the system, in millicores.
        public var cpuSystemReserveMilli: Int64?
        /// Memory capacity, in bytes.
        public var memCapacityBytes: Int64?
        /// Memory reserved for the system, in bytes.
        public var memSystemReserveBytes: Int64?
        /// Memory reserved for eviction headroom, in bytes.
        public var memEvictionReserveBytes: Int64?
        /// Memory allocatable to workloads, in bytes.
        public var memAllocatableBytes: Int64?
        /// Total swap, in bytes.
        public var swapTotalBytes: Int64?
        /// Swap in use, in bytes.
        public var swapUsedBytes: Int64?
        /// Logical CPUs in the performance cluster. Nil on a host with no
        /// performance level split, and on a page or object that predates it.
        public var cpuPerformanceCores: Int64?
        /// Logical CPUs in the efficiency cluster. Nil on a host with no
        /// performance level split, and on a page or object that predates it.
        public var cpuEfficiencyCores: Int64?
        /// Whether the node advertises a GPU to pods. Nil when the producer
        /// does not know, and on a page or object that predates it.
        public var gpuPresent: Bool?
        /// The number of GPUs the node advertises to pods, 0 when it
        /// advertises none. Nil on a page or object that predates it.
        public var gpuCount: Int64?

        /// The wire keys.
        enum CodingKeys: String, CodingKey, CaseIterable {
            case cpuCapacityMilli, cpuSystemReserveMilli, memCapacityBytes, memSystemReserveBytes
            case memEvictionReserveBytes, memAllocatableBytes, swapTotalBytes, swapUsedBytes
            case cpuPerformanceCores, cpuEfficiencyCores, gpuPresent, gpuCount
        }
    }

    /// How much more the node can take.
    public struct Recommendation: Codable, Equatable, Sendable {
        /// Memory a workload can safely add, in bytes.
        public var safeAdditionalBytes: Int64?
        /// The signal the recommendation rests on.
        public var basis: SignalID?

        /// The wire keys.
        enum CodingKeys: String, CodingKey, CaseIterable {
            case safeAdditionalBytes, basis
        }
    }

    /// The kill mode and whether it is armed.
    public struct KillMode: Codable, Equatable, Sendable {
        /// The configured mode.
        public var mode: KillModeName?
        /// Whether killing is armed.
        public var armed: Bool?
        /// How many pressure episodes the node has observed while arming.
        public var armingEpisodes: Int32?
        /// Why the mode is armed or not.
        public var reason: KillModeReason?

        /// The wire keys.
        enum CodingKeys: String, CodingKey, CaseIterable {
            case mode, armed, armingEpisodes, reason
        }
    }

    /// The last tier-1 kill decision, armed or observed: the band and the trigger.
    public struct WouldKill: Codable, Equatable, Sendable {
        /// The band.
        public var band: Band
        /// Why.
        public var reason: WouldKillReason
        /// When the node decided it.
        public var at: Timestamp

        /// The wire keys.
        enum CodingKeys: String, CodingKey, CaseIterable {
            case band, reason, at
        }
    }

    /// The counters of one band.
    public struct BandCounters: Codable, Equatable, Sendable {
        /// The band.
        public var band: Band
        /// Evictions.
        public var evictionsTotal: Int64
        /// Out-of-memory kills.
        public var oomKillsTotal: Int64
        /// Kills by the kernel.
        public var kernelKillsTotal: Int64
        /// Restarts.
        public var restartsTotal: Int64
        /// Memory-high events.
        public var memHighEventsTotal: Int64
        /// Refused first-tier deliveries.
        public var tier1RefusedTotal: Int64
        /// Counts over recent windows.
        public var windows: [WindowCount]?

        /// The wire keys.
        enum CodingKeys: String, CodingKey, CaseIterable {
            case band, evictionsTotal, oomKillsTotal, kernelKillsTotal, restartsTotal
            case memHighEventsTotal, tier1RefusedTotal, windows
        }
    }

    /// A count of one reason over one window.
    public struct WindowCount: Codable, Equatable, Sendable {
        /// The window.
        public var window: CounterWindow
        /// What is counted.
        public var reason: CounterReason
        /// The count.
        public var count: Int64

        /// The wire keys.
        enum CodingKeys: String, CodingKey, CaseIterable {
            case window, reason, count
        }
    }

    /// The policy the node applied, and the outcome.
    public struct AppliedPolicy: Codable, Equatable, Sendable {
        /// The policy's name.
        public var name: String
        /// The policy's resourceVersion.
        public var resourceVersion: String?
        /// What became of the policy.
        public var outcome: PolicyOutcome
        /// The fields the node clamped.
        public var clampedFields: [PolicyField]?

        /// The wire keys.
        enum CodingKeys: String, CodingKey, CaseIterable {
            case name, resourceVersion, outcome, clampedFields
        }
    }

    /// A reference to a policy at a resourceVersion.
    public struct PolicyRef: Codable, Equatable, Sendable {
        /// The policy's name.
        public var name: String
        /// The policy's resourceVersion.
        public var resourceVersion: String?

        /// The wire keys.
        enum CodingKeys: String, CodingKey, CaseIterable {
            case name, resourceVersion
        }
    }

    /// How the status reached the API server.
    public struct Writer: Codable, Equatable, Sendable {
        /// The writer's shape.
        public var shape: WriterShape
        /// Whether an own-node writer verified its token's node-name claim at start.
        public var nodeNameExtra: Bool?

        /// The wire keys.
        enum CodingKeys: String, CodingKey, CaseIterable {
            case shape, nodeNameExtra
        }
    }

    /// The macOS memory signals.
    public struct DarwinSignals: Codable, Equatable, Sendable {
        /// The kernel's VM pressure level.
        public var vmPressureLevel: Int64?
        /// The memorystatus level, in permille.
        public var memorystatusLevelPermille: Int64?
        /// The compressor.
        public var compressor: DarwinCompressor?
        /// Pages swapped in since boot.
        public var swapinsTotal: Int64?
        /// Pages swapped out since boot.
        public var swapoutsTotal: Int64?

        /// The wire keys.
        enum CodingKeys: String, CodingKey, CaseIterable {
            case vmPressureLevel, memorystatusLevelPermille, compressor, swapinsTotal, swapoutsTotal
        }
    }

    /// The macOS memory compressor.
    public struct DarwinCompressor: Codable, Equatable, Sendable {
        /// Bytes the compressor occupies.
        public var bytesUsed: Int64?
        /// Uncompressed bytes the compressor holds.
        public var bytesStored: Int64?
        /// The compressor's segment limit, in bytes.
        public var segmentLimitBytes: Int64?

        /// The wire keys.
        enum CodingKeys: String, CodingKey, CaseIterable {
            case bytesUsed, bytesStored, segmentLimitBytes
        }
    }

    /// The Linux pressure signals.
    public struct LinuxSignals: Codable, Equatable, Sendable {
        /// Pressure stall information.
        public var psi: LinuxPSI?
        /// The memory cgroup's event counters.
        public var memoryEvents: MemoryEvents?

        /// The wire keys.
        enum CodingKeys: String, CodingKey, CaseIterable {
            case psi, memoryEvents
        }
    }

    /// Pressure stall information per resource.
    public struct LinuxPSI: Codable, Equatable, Sendable {
        /// CPU.
        public var cpu: PSIResource?
        /// Memory.
        public var memory: PSIResource?
        /// IO.
        public var io: PSIResource?

        /// The wire keys.
        enum CodingKeys: String, CodingKey, CaseIterable {
            case cpu, memory, io
        }
    }

    /// The two stall lines of one resource.
    public struct PSIResource: Codable, Equatable, Sendable {
        /// Some tasks stalled.
        public var some: PSILine?
        /// All tasks stalled.
        public var full: PSILine?

        /// The wire keys.
        enum CodingKeys: String, CodingKey, CaseIterable {
            case some, full
        }
    }

    /// One stall line.
    public struct PSILine: Codable, Equatable, Sendable {
        /// The 10-second average, in permille.
        public var avg10Permille: Int64?
        /// The 60-second average, in permille.
        public var avg60Permille: Int64?
        /// Total stall time, in microseconds.
        public var totalUs: Int64?

        /// The wire keys.
        enum CodingKeys: String, CodingKey, CaseIterable {
            case avg10Permille, avg60Permille, totalUs
        }
    }

    /// The memory cgroup's event counters.
    public struct MemoryEvents: Codable, Equatable, Sendable {
        /// memory.high breaches.
        public var high: Int64?
        /// memory.max hits.
        public var max: Int64?
        /// Out-of-memory events.
        public var oom: Int64?
        /// Out-of-memory kills.
        public var oomKill: Int64?

        /// The wire keys.
        enum CodingKeys: String, CodingKey, CaseIterable {
            case high, max, oom, oomKill
        }
    }

    /// A status condition, in the Kubernetes condition shape.
    public struct Condition: Codable, Equatable, Sendable {
        /// The condition type (see `NodeBudget.ConditionType`).
        public var type: String
        /// Whether the condition holds.
        public var status: ConditionStatus
        /// The generation the condition was set for.
        public var observedGeneration: Int64?
        /// When the status last changed.
        public var lastTransitionTime: Timestamp
        /// A machine-readable reason (see `NodeBudget.ConditionReason`).
        public var reason: String
        /// A human-readable message, possibly empty.
        public var message: String

        /// The wire keys.
        enum CodingKeys: String, CodingKey, CaseIterable {
            case type, status, observedGeneration, lastTransitionTime, reason, message
        }
    }
}
