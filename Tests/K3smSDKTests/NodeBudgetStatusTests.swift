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
import K3smSDK
import Testing

// MARK: - fixtures

/// The vendored goldens, verified against Fixtures/nodebudget/FIXTURES.sha256
/// by hack/verify-fixtures.sh.
private let goldenNames = ["darwin.golden.json", "linux.golden.json"]

private func golden(_ name: String) throws -> Data {
    let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/nodebudget")
    return try Data(contentsOf: dir.appendingPathComponent(name))
}

// MARK: - a JSON value that keeps integers exact

/// A JSON document as a value. Integers stay Int64, so a 64-bit quantity
/// compares exactly; objects compare without regard to key order.
private enum JSONValue: Decodable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let v = try? c.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? c.decode(Int64.self) {
            self = .int(v)
        } else if let v = try? c.decode(Double.self) {
            self = .double(v)
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else if let v = try? c.decode([JSONValue].self) {
            self = .array(v)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }

    static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }
}

// MARK: - the key registry

/// The wire keys of the type at each object path of a NodeBudget document.
/// An array element is spelled "[]". A path in `freeMaps` holds arbitrary keys.
private let keyRegistry: [String: [String]] = [
    "": keys(NodeBudget.CodingKeys.self),
    "metadata": keys(ObjectMetadata.CodingKeys.self),
    "status": keys(NodeBudgetStatus.CodingKeys.self),
    "status.capacity": keys(Capacity.CodingKeys.self),
    "status.signals[]": keys(Signal.CodingKeys.self),
    "status.recommendation": keys(Recommendation.CodingKeys.self),
    "status.killMode": keys(KillMode.CodingKeys.self),
    "status.wouldKill": keys(WouldKill.CodingKeys.self),
    "status.counters[]": keys(BandCounters.CodingKeys.self),
    "status.counters[].windows[]": keys(WindowCount.CodingKeys.self),
    "status.policy": keys(AppliedPolicy.CodingKeys.self),
    "status.inForce": keys(PolicyRef.CodingKeys.self),
    "status.writer": keys(Writer.CodingKeys.self),
    "status.conditions[]": keys(Condition.CodingKeys.self),
    "status.darwin": keys(DarwinSignals.CodingKeys.self),
    "status.darwin.compressor": keys(DarwinCompressor.CodingKeys.self),
    "status.linux": keys(LinuxSignals.CodingKeys.self),
    "status.linux.psi": keys(LinuxPSI.CodingKeys.self),
    "status.linux.psi.cpu": keys(PSIResource.CodingKeys.self),
    "status.linux.psi.memory": keys(PSIResource.CodingKeys.self),
    "status.linux.psi.io": keys(PSIResource.CodingKeys.self),
    "status.linux.psi.cpu.some": keys(PSILine.CodingKeys.self),
    "status.linux.psi.cpu.full": keys(PSILine.CodingKeys.self),
    "status.linux.psi.memory.some": keys(PSILine.CodingKeys.self),
    "status.linux.psi.memory.full": keys(PSILine.CodingKeys.self),
    "status.linux.psi.io.some": keys(PSILine.CodingKeys.self),
    "status.linux.psi.io.full": keys(PSILine.CodingKeys.self),
    "status.linux.memoryEvents": keys(MemoryEvents.CodingKeys.self),
]

private let freeMaps: Set<String> = ["metadata.labels", "metadata.annotations"]

private func keys<K: CodingKey & CaseIterable>(_: K.Type) -> [String] {
    K.allCases.map(\.stringValue)
}

/// Every key of every object in `value`, as "path: key" for each key the
/// registry does not model (or "path: <no type>" for an unregistered object).
/// `visited` counts the keys checked, so the walk cannot pass vacuously.
private func unmodelledKeys(_ value: JSONValue, at path: String, visited: inout Int) -> [String] {
    switch value {
    case let .object(fields):
        if freeMaps.contains(path) { return [] }
        guard let known = keyRegistry[path] else { return ["\(path): <no type>"] }
        var out: [String] = []
        for (key, child) in fields.sorted(by: { $0.key < $1.key }) {
            visited += 1
            if !known.contains(key) { out.append("\(path.isEmpty ? "<root>" : path): \(key)") }
            out += unmodelledKeys(child, at: path.isEmpty ? key : "\(path).\(key)", visited: &visited)
        }
        return out
    case let .array(items):
        return items.flatMap { unmodelledKeys($0, at: path + "[]", visited: &visited) }
    default:
        return []
    }
}

private func reencode<T: Encodable>(_ value: T) throws -> JSONValue {
    try JSONValue.parse(JSONEncoder().encode(value))
}

// MARK: - the gate

@Test("the status types cover every key of the golden NodeBudget documents", arguments: goldenNames)
func statusTypesCoverGoldenNodeBudgetDocuments(_ name: String) throws {
    let data = try golden(name)
    let want = try JSONValue.parse(data)

    var visited = 0
    let missing = unmodelledKeys(want, at: "", visited: &visited)
    #expect(missing.isEmpty, "golden keys the types do not model: \(missing)")
    #expect(visited > 40, "the key walk checked only \(visited) keys")

    let budget = try NodeBudgetDecoder.decodeBudget(data)
    #expect(try reencode(budget) == want, "\(name) does not survive decode and re-encode")
}

// MARK: - the JSON value itself

@Test("the comparison value keeps 64-bit integers exact and tells 0 from false")
func jsonValueIsExact() throws {
    let v = try JSONValue.parse(Data(#"[9223372036854775807, 0, false, 9007199254740993]"#.utf8))
    #expect(v == .array([.int(Int64.max), .int(0), .bool(false), .int(9_007_199_254_740_993)]))
}

// MARK: - forward compatibility

private func jsonObject(_ data: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func jsonData(_ object: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: object)
}

/// The darwin golden with `edit` applied to its status object.
private func darwinWithStatus(_ edit: (inout [String: Any]) throws -> Void) throws -> Data {
    var root = try jsonObject(golden("darwin.golden.json"))
    var status = try #require(root["status"] as? [String: Any])
    try edit(&status)
    root["status"] = status
    return try jsonData(root)
}

/// Applies `edit` to the element at `index` of the array under `key`.
private func editElement(
    _ object: inout [String: Any], _ key: String, _ index: Int, _ edit: (inout [String: Any]) -> Void
) throws {
    var items = try #require(object[key] as? [Any])
    var item = try #require(items[index] as? [String: Any])
    edit(&item)
    items[index] = item
    object[key] = items
}

@Test("unknown keys at the root, the status, a signal and a counter decode and are dropped on re-encode")
func unknownKeysAreIgnored() throws {
    let base = try golden("darwin.golden.json")
    var root = try jsonObject(base)
    root["futureRoot"] = ["x": 1]
    var status = try #require(root["status"] as? [String: Any])
    status["futureStatus"] = "y"
    try editElement(&status, "signals", 0) { $0["futureSignal"] = [1, 2] }
    try editElement(&status, "counters", 0) { $0["futureCounter"] = 7 }
    root["status"] = status

    let budget = try NodeBudgetDecoder.decodeBudget(jsonData(root))
    #expect(try reencode(budget) == JSONValue.parse(base))
}

@Test("an unknown enum value decodes, is not known, and round-trips")
func unknownEnumRoundTrips() throws {
    let data = try darwinWithStatus { $0["level"] = "melting" }
    let budget = try NodeBudgetDecoder.decodeBudget(data)
    let level = try #require(budget.status?.level)
    #expect(level.rawValue == "melting")
    #expect(!level.isKnown)
    #expect(Level.critical.isKnown)
    #expect(try reencode(budget) == JSONValue.parse(data))
}

@Test("a bare status object decodes without an apiVersion")
func bareStatusDecodes() throws {
    let root = try jsonObject(golden("linux.golden.json"))
    let status = try NodeBudgetDecoder.decodeStatus(jsonData(try #require(root["status"])))
    let budget = try NodeBudgetDecoder.decodeBudget(golden("linux.golden.json"))
    #expect(status == budget.status)
    #expect(status.signals?.first?.id == .memoryAvailable)
    #expect(status.capacity?.memCapacityBytes == 34_359_738_368)
}

@Test("a list decodes its items")
func listDecodes() throws {
    let items = try goldenNames.map { try jsonObject(golden($0)) }
    let list: [String: Any] = [
        "apiVersion": K3smSDKVersion.nodeBudgetAPIVersion, "kind": "NodeBudgetList",
        "metadata": ["resourceVersion": "12"], "items": items,
    ]
    let decoded = try NodeBudgetDecoder.decodeList(jsonData(list))
    #expect(decoded.items.map { $0.metadata?.name } == ["mac-worker-1", "linux-worker-1"])
    #expect(decoded.metadata?.resourceVersion == "12")
}

@Test("times decode with fractional seconds and offsets and encode as whole UTC seconds")
func timestamps() throws {
    let data = try darwinWithStatus { $0["observedAt"] = "2026-10-19T14:00:00.750+02:00" }
    let budget = try NodeBudgetDecoder.decodeBudget(data)
    #expect(budget.status?.observedAt?.date.timeIntervalSince1970 == 1_792_411_200.75)
    #expect(try reencode(budget) == JSONValue.parse(golden("darwin.golden.json")))
}

// MARK: - malformed documents

private struct MalformedCase: Sendable, CustomStringConvertible {
    let description: String
    let data: @Sendable () throws -> Data
    let want: NodeBudgetDecodeError
}

private let malformedCases: [MalformedCase] = [
    MalformedCase(description: "a string for an integer", data: {
        try darwinWithStatus { $0["producerGeneration"] = "4" }
    }, want: .malformed(path: "status.producerGeneration", reason: "")),
    MalformedCase(description: "a signal without its id", data: {
        try darwinWithStatus { try editElement(&$0, "signals", 0) { $0.removeValue(forKey: "id") } }
    }, want: .malformed(path: "status.signals[0].id", reason: "")),
    MalformedCase(description: "a string for admit", data: {
        try darwinWithStatus { $0["admit"] = "yes" }
    }, want: .malformed(path: "status.admit", reason: "")),
    MalformedCase(description: "a time that is not RFC 3339", data: {
        try darwinWithStatus { $0["observedAt"] = "2026-13-19T12:00:00Z" }
    }, want: .malformed(path: "status.observedAt", reason: "")),
    MalformedCase(description: "truncated JSON", data: {
        let d = try golden("darwin.golden.json")
        return d.prefix(d.count / 2)
    }, want: .notJSON),
    MalformedCase(description: "empty data", data: { Data() }, want: .notJSON),
    MalformedCase(description: "the wrong apiVersion", data: {
        var root = try jsonObject(golden("darwin.golden.json"))
        root["apiVersion"] = "budget.k3sm.io/v1beta9"
        return try jsonData(root)
    }, want: .unsupportedVersion),
    MalformedCase(description: "a top-level array", data: {
        try jsonData([jsonObject(golden("darwin.golden.json"))])
    }, want: .malformed(path: "", reason: "")),
]

@Test("each malformed document gives its typed error and path", arguments: malformedCases)
private func malformedDocuments(_ c: MalformedCase) throws {
    let data = try c.data()
    let err = #expect(throws: NodeBudgetDecodeError.self) { try NodeBudgetDecoder.decodeBudget(data) }
    switch (err, c.want) {
    case let (.malformed(path, reason)?, .malformed(wantPath, _)):
        #expect(path == wantPath)
        #expect(!reason.isEmpty)
    default:
        #expect(err == c.want)
    }
}

@Test("a bare status reports paths from the status root")
func bareStatusPaths() throws {
    var status = try #require(jsonObject(golden("linux.golden.json"))["status"] as? [String: Any])
    try editElement(&status, "signals", 0) { $0["value"] = "big" }
    let data = try jsonData(status)
    let err = #expect(throws: NodeBudgetDecodeError.self) { try NodeBudgetDecoder.decodeStatus(data) }
    guard case let .malformed(path, _)? = err else {
        Issue.record("want a malformed error, got \(String(describing: err))")
        return
    }
    #expect(path == "signals[0].value")
}
