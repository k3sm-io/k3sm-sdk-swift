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

/// One signal record: a signal's value, its threshold ladder and how it moves.
/// Thresholds and releases share the signal's unit.
public struct Signal: Codable, Equatable, Sendable {
    /// The signal.
    public var id: SignalID
    /// The unit of the value and every threshold.
    public var unit: SignalUnit
    /// The current value.
    public var value: Int64?
    /// The warn rung.
    public var warnThreshold: Int64?
    /// The rung at which the node stops admitting.
    public var admitStopThreshold: Int64?
    /// The critical rung.
    public var criticalThreshold: Int64?
    /// The soft-eviction rung.
    public var evictSoftThreshold: Int64?
    /// The hard-eviction rung.
    public var evictHardThreshold: Int64?
    /// The value at which the warn rung releases.
    public var warnRelease: Int64?
    /// The value at which the admit-stop rung releases.
    public var admitStopRelease: Int64?
    /// The value at which the critical rung releases.
    public var criticalRelease: Int64?
    /// The value at which the soft-eviction rung releases.
    public var evictSoftRelease: Int64?
    /// The value at which the hard-eviction rung releases.
    public var evictHardRelease: Int64?
    /// The soft-eviction grace, in seconds.
    public var graceSeconds: Int64?
    /// The least an eviction reclaims, in bytes.
    public var minReclaimBytes: Int64?
    /// The window a rate signal is measured over, in seconds.
    public var windowSeconds: Int64?
    /// The estimated seconds until the next rung.
    public var etaToNextRungSeconds: Int64?
    /// The direction the signal is moving in.
    public var trend: Trend?
    /// The resource that limits the signal.
    public var limitingResource: LimitingResource?
    /// The signal this one shares its filesystem with.
    public var sharedWith: SignalID?

    /// The wire keys.
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case id, unit, value
        case warnThreshold, admitStopThreshold, criticalThreshold, evictSoftThreshold, evictHardThreshold
        case warnRelease, admitStopRelease, criticalRelease, evictSoftRelease, evictHardRelease
        case graceSeconds, minReclaimBytes, windowSeconds, etaToNextRungSeconds
        case trend, limitingResource, sharedWith
    }
}
