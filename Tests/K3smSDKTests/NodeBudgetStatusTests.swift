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
@testable import K3smSDK
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
    "metadata": keys(NodeBudget.ObjectMetadata.CodingKeys.self),
    "status": keys(NodeBudgetStatus.CodingKeys.self),
    "status.capacity": keys(NodeBudget.Capacity.CodingKeys.self),
    "status.signals[]": keys(NodeBudget.Signal.CodingKeys.self),
    "status.recommendation": keys(NodeBudget.Recommendation.CodingKeys.self),
    "status.killMode": keys(NodeBudget.KillMode.CodingKeys.self),
    "status.wouldKill": keys(NodeBudget.WouldKill.CodingKeys.self),
    "status.counters[]": keys(NodeBudget.BandCounters.CodingKeys.self),
    "status.counters[].windows[]": keys(NodeBudget.WindowCount.CodingKeys.self),
    "status.policy": keys(NodeBudget.AppliedPolicy.CodingKeys.self),
    "status.inForce": keys(NodeBudget.PolicyRef.CodingKeys.self),
    "status.writer": keys(NodeBudget.Writer.CodingKeys.self),
    "status.conditions[]": keys(NodeBudget.Condition.CodingKeys.self),
    "status.darwin": keys(NodeBudget.DarwinSignals.CodingKeys.self),
    "status.darwin.compressor": keys(NodeBudget.DarwinCompressor.CodingKeys.self),
    "status.linux": keys(NodeBudget.LinuxSignals.CodingKeys.self),
    "status.linux.psi": keys(NodeBudget.LinuxPSI.CodingKeys.self),
    "status.linux.psi.cpu": keys(NodeBudget.PSIResource.CodingKeys.self),
    "status.linux.psi.memory": keys(NodeBudget.PSIResource.CodingKeys.self),
    "status.linux.psi.io": keys(NodeBudget.PSIResource.CodingKeys.self),
    "status.linux.psi.cpu.some": keys(NodeBudget.PSILine.CodingKeys.self),
    "status.linux.psi.cpu.full": keys(NodeBudget.PSILine.CodingKeys.self),
    "status.linux.psi.memory.some": keys(NodeBudget.PSILine.CodingKeys.self),
    "status.linux.psi.memory.full": keys(NodeBudget.PSILine.CodingKeys.self),
    "status.linux.psi.io.some": keys(NodeBudget.PSILine.CodingKeys.self),
    "status.linux.psi.io.full": keys(NodeBudget.PSILine.CodingKeys.self),
    "status.linux.memoryEvents": keys(NodeBudget.MemoryEvents.CodingKeys.self),
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
    #expect(NodeBudget.Level.critical.isKnown)
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
        "apiVersion": K3smSDKVersion.nodeBudgetAPIVersion, "kind": K3smSDKVersion.nodeBudgetListKind,
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

// MARK: - the document kind

/// The golden darwin document with its kind set, or removed when nil.
private func darwinWithKind(_ kind: String?) throws -> Data {
    var root = try jsonObject(golden("darwin.golden.json"))
    root["kind"] = kind
    return try jsonData(root)
}

/// A NodeBudgetList holding both goldens, with its kind set, or removed when nil.
private func listWithKind(_ kind: String?) throws -> Data {
    var list: [String: Any] = [
        "apiVersion": K3smSDKVersion.nodeBudgetAPIVersion,
        "items": try goldenNames.map { try jsonObject(golden($0)) },
    ]
    list["kind"] = kind
    return try jsonData(list)
}

private struct KindCase: Sendable, CustomStringConvertible {
    let description: String
    let list: Bool
    let data: @Sendable () throws -> Data
    let want: NodeBudgetDecodeError
}

private let kindCases: [KindCase] = [
    KindCase(description: "a NodeBudgetPolicy passed to decodeBudget", list: false,
             data: { try darwinWithKind("NodeBudgetPolicy") }, want: .unsupportedKind("NodeBudgetPolicy")),
    KindCase(description: "a NodeBudget without a kind passed to decodeBudget", list: false,
             data: { try darwinWithKind(nil) }, want: .unsupportedKind("")),
    KindCase(description: "a kind that is not a string passed to decodeBudget", list: false,
             data: {
                 var root = try jsonObject(golden("darwin.golden.json"))
                 root["kind"] = 7
                 return try jsonData(root)
             }, want: .unsupportedKind("")),
    KindCase(description: "a NodeBudgetList passed to decodeBudget", list: false,
             data: { try listWithKind(K3smSDKVersion.nodeBudgetListKind) },
             want: .unsupportedKind("NodeBudgetList")),
    KindCase(description: "a NodeBudget passed to decodeList", list: true,
             data: { try golden("darwin.golden.json") }, want: .unsupportedKind("NodeBudget")),
    KindCase(description: "a NodeBudgetPolicy passed to decodeList", list: true,
             data: { try listWithKind("NodeBudgetPolicy") }, want: .unsupportedKind("NodeBudgetPolicy")),
    KindCase(description: "a list without a kind passed to decodeList", list: true,
             data: { try listWithKind(nil) }, want: .unsupportedKind("")),
]

@Test("a missing or different kind gives unsupportedKind", arguments: kindCases)
private func wrongKind(_ c: KindCase) throws {
    let data = try c.data()
    let err = #expect(throws: NodeBudgetDecodeError.self) {
        if c.list { _ = try NodeBudgetDecoder.decodeList(data) } else { _ = try NodeBudgetDecoder.decodeBudget(data) }
    }
    #expect(err == c.want)
}

@Test("the apiVersion is checked before the kind")
func versionBeforeKind() throws {
    var root = try jsonObject(golden("darwin.golden.json"))
    root["apiVersion"] = "budget.k3sm.io/v1beta9"
    root["kind"] = "NodeBudgetPolicy"
    let data = try jsonData(root)
    #expect(throws: NodeBudgetDecodeError.unsupportedVersion) { try NodeBudgetDecoder.decodeBudget(data) }
}

@Test("a bare status is decoded whatever apiVersion and kind keys it carries")
func bareStatusIgnoresKind() throws {
    var status = try #require(jsonObject(golden("linux.golden.json"))["status"] as? [String: Any])
    status["apiVersion"] = "other/v9"
    status["kind"] = "NodeBudgetPolicy"
    let decoded = try NodeBudgetDecoder.decodeStatus(jsonData(status))
    #expect(decoded.platform == .linux)
}

@Test("a bare status that is not an object or not JSON gives the typed error")
func bareStatusShape() throws {
    let notObject = Data("[1]".utf8)
    #expect(throws: NodeBudgetDecodeError.malformed(path: "", reason: "the document is not a JSON object")) {
        try NodeBudgetDecoder.decodeStatus(notObject)
    }
    #expect(throws: NodeBudgetDecodeError.notJSON) { try NodeBudgetDecoder.decodeStatus(Data("{".utf8)) }
}

@Test("the CPU core split and the GPU presence decode, and are nil on an object without them")
func capacityCoreSplitAndGPU() throws {
    let darwin = try #require(try NodeBudgetDecoder.decodeBudget(golden("darwin.golden.json")).status?.capacity)
    #expect(darwin.cpuPerformanceCores == 4)
    #expect(darwin.cpuEfficiencyCores == 4)
    #expect(darwin.gpuPresent == true)
    #expect(darwin.gpuCount == 1)

    let linux = try #require(try NodeBudgetDecoder.decodeBudget(golden("linux.golden.json")).status?.capacity)
    #expect(linux.cpuPerformanceCores == nil)
    #expect(linux.cpuEfficiencyCores == nil)
    #expect(linux.gpuPresent == false)
    #expect(linux.gpuCount == 0)

    let older = try darwinWithStatus { status in
        var capacity = status["capacity"] as? [String: Any] ?? [:]
        for key in ["cpuPerformanceCores", "cpuEfficiencyCores", "gpuPresent", "gpuCount"] {
            capacity.removeValue(forKey: key)
        }
        status["capacity"] = capacity
    }
    let before = try #require(try NodeBudgetDecoder.decodeBudget(older).status?.capacity)
    #expect(before.cpuPerformanceCores == nil)
    #expect(before.cpuEfficiencyCores == nil)
    #expect(before.gpuPresent == nil)
    #expect(before.gpuCount == nil)
    #expect(before.memCapacityBytes == darwin.memCapacityBytes)
}
