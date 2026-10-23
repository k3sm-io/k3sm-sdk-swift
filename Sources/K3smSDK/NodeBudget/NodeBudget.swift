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

import Foundation

/// A NodeBudget custom resource (budget.k3sm.io/v1alpha1): the node pressure
/// and headroom a node publishes. The SDK only reads it; it has no spec.
public struct NodeBudget: Codable, Equatable, Sendable {
    /// The resource's apiVersion.
    public var apiVersion: String?
    /// The resource's kind.
    public var kind: String?
    /// The object metadata.
    public var metadata: ObjectMetadata?
    /// The node's budget.
    public var status: NodeBudgetStatus?

    /// The wire keys.
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case apiVersion, kind, metadata, status
    }
}

/// A list of NodeBudgets, as the API server returns it.
public struct NodeBudgetList: Codable, Equatable, Sendable {
    /// The list's apiVersion.
    public var apiVersion: String?
    /// The list's kind.
    public var kind: String?
    /// The list metadata.
    public var metadata: ListMetadata?
    /// The NodeBudgets.
    public var items: [NodeBudget]

    /// The wire keys.
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case apiVersion, kind, metadata, items
    }
}

/// The object metadata fields the SDK reads. Other metadata is ignored.
public struct ObjectMetadata: Codable, Equatable, Sendable {
    /// The object's name: the node's name.
    public var name: String?
    /// The object's resourceVersion.
    public var resourceVersion: String?
    /// The object's uid.
    public var uid: String?
    /// When the object was created.
    public var creationTimestamp: Timestamp?
    /// The object's generation.
    public var generation: Int64?
    /// The object's labels.
    public var labels: [String: String]?
    /// The object's annotations.
    public var annotations: [String: String]?

    /// The wire keys.
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case name, resourceVersion, uid, creationTimestamp, generation, labels, annotations
    }
}

/// The list metadata fields the SDK reads.
public struct ListMetadata: Codable, Equatable, Sendable {
    /// The list's resourceVersion.
    public var resourceVersion: String?
    /// The continue token of a paged list.
    public var `continue`: String?
    /// How many items remain after this page.
    public var remainingItemCount: Int64?

    /// The wire keys.
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case resourceVersion, `continue`, remainingItemCount
    }
}

/// A point in time on the wire: an RFC 3339 string. Decoding accepts
/// fractional seconds and any UTC offset; encoding writes whole seconds in UTC
/// with a `Z`, as the Kubernetes API does.
public struct Timestamp: Codable, Hashable, Sendable {
    /// The time.
    public var date: Date

    /// Wraps a date.
    public init(_ date: Date) { self.date = date }

    /// Decodes an RFC 3339 string.
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        guard let d = Timestamp.parse(s) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "not an RFC 3339 time: \(s)")
        }
        date = d
    }

    /// Encodes whole seconds in UTC, as "YYYY-MM-DDTHH:MM:SSZ".
    public func encode(to encoder: Encoder) throws {
        guard let s = Timestamp.format(date) else {
            throw EncodingError.invalidValue(date, EncodingError.Context(
                codingPath: encoder.codingPath, debugDescription: "year outside 0...9999"))
        }
        var c = encoder.singleValueContainer()
        try c.encode(s)
    }

    /// Parses "YYYY-MM-DDTHH:MM:SS[.fraction](Z|+HH:MM|-HH:MM)".
    static func parse(_ s: String) -> Date? {
        let b = Array(s.utf8)
        var i = 0
        func digits(_ n: Int) -> Int64? {
            guard i + n <= b.count else { return nil }
            var v: Int64 = 0
            for k in i..<(i + n) {
                guard b[k] >= 0x30, b[k] <= 0x39 else { return nil }
                v = v * 10 + Int64(b[k] - 0x30)
            }
            i += n
            return v
        }
        func expect(_ chars: String) -> Bool {
            guard i < b.count, chars.utf8.contains(b[i]) else { return false }
            i += 1
            return true
        }
        guard let year = digits(4), expect("-"), let month = digits(2), expect("-"), let day = digits(2),
              expect("Tt"), let hour = digits(2), expect(":"), let minute = digits(2), expect(":"),
              let second = digits(2)
        else { return nil }
        guard (1...12).contains(month), (1...daysIn(month: month, year: year)).contains(day),
              hour < 24, minute < 60, second < 60
        else { return nil }
        var fraction = 0.0
        if i < b.count, b[i] == 0x2E {
            i += 1
            var scale = 0.1
            let start = i
            while i < b.count, b[i] >= 0x30, b[i] <= 0x39 {
                fraction += Double(b[i] - 0x30) * scale
                scale /= 10
                i += 1
            }
            guard i > start else { return nil }
        }
        var offset: Int64 = 0
        if expect("Zz") {
            offset = 0
        } else if i < b.count, b[i] == 0x2B || b[i] == 0x2D {
            let sign: Int64 = b[i] == 0x2B ? 1 : -1
            i += 1
            guard let oh = digits(2), expect(":"), let om = digits(2), oh < 24, om < 60 else { return nil }
            offset = sign * (oh * 3600 + om * 60)
        } else {
            return nil
        }
        guard i == b.count else { return nil }
        let days = daysFromCivil(year: year, month: month, day: day)
        let seconds = days * 86400 + hour * 3600 + minute * 60 + second - offset
        return Date(timeIntervalSince1970: Double(seconds) + fraction)
    }

    /// Formats whole seconds in UTC, or nil for a year outside 0...9999.
    static func format(_ date: Date) -> String? {
        let t = date.timeIntervalSince1970.rounded(.down)
        guard t.isFinite, abs(t) < 1e15 else { return nil }
        let total = Int64(t)
        var days = total / 86400
        var rem = total % 86400
        if rem < 0 {
            rem += 86400
            days -= 1
        }
        let (y, m, d) = civilFromDays(days)
        guard (0...9999).contains(y) else { return nil }
        func pad(_ v: Int64, _ w: Int) -> String {
            let s = String(v)
            return String(repeating: "0", count: max(0, w - s.count)) + s
        }
        return "\(pad(y, 4))-\(pad(m, 2))-\(pad(d, 2))T\(pad(rem / 3600, 2)):\(pad(rem % 3600 / 60, 2)):\(pad(rem % 60, 2))Z"
    }

    private static func daysIn(month: Int64, year: Int64) -> Int64 {
        switch month {
        case 2: return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    // Days since 1970-01-01 in the proleptic Gregorian calendar, after
    // Howard Hinnant's days_from_civil (public domain).
    private static func daysFromCivil(year: Int64, month: Int64, day: Int64) -> Int64 {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    // The inverse of daysFromCivil, after Howard Hinnant's civil_from_days.
    private static func civilFromDays(_ days: Int64) -> (Int64, Int64, Int64) {
        let z = days + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (m <= 2 ? 1 : 0), m, d)
    }
}

/// Decodes NodeBudget documents from JSON the caller already holds. It does
/// no I/O; reading the document is the caller's job.
public enum NodeBudgetDecoder {
    /// Decodes one NodeBudget. Its apiVersion must be
    /// `K3smSDKVersion.nodeBudgetAPIVersion`.
    public static func decodeBudget(_ data: Data) throws(NodeBudgetDecodeError) -> NodeBudget {
        try decode(NodeBudget.self, from: data, checkVersion: true)
    }

    /// Decodes a NodeBudgetList. Its apiVersion must be
    /// `K3smSDKVersion.nodeBudgetAPIVersion`.
    public static func decodeList(_ data: Data) throws(NodeBudgetDecodeError) -> NodeBudgetList {
        try decode(NodeBudgetList.self, from: data, checkVersion: true)
    }

    /// Decodes a bare status object, such as the `status` of a NodeBudget.
    /// It carries no apiVersion, so none is checked.
    public static func decodeStatus(_ data: Data) throws(NodeBudgetDecodeError) -> NodeBudgetStatus {
        try decode(NodeBudgetStatus.self, from: data, checkVersion: false)
    }

    private static func decode<T: Decodable>(
        _ type: T.Type, from data: Data, checkVersion: Bool
    ) throws(NodeBudgetDecodeError) -> T {
        let top: Any
        do {
            top = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw .notJSON
        }
        guard let object = top as? [String: Any] else {
            throw .malformed(path: "", reason: "the document is not a JSON object")
        }
        if checkVersion, object["apiVersion"] as? String != K3smSDKVersion.nodeBudgetAPIVersion {
            throw .unsupportedVersion
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch let error as DecodingError {
            throw NodeBudgetDecodeError(error)
        } catch {
            throw .malformed(path: "", reason: String(describing: error))
        }
    }
}
