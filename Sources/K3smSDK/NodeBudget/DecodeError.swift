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

/// Why a NodeBudget document did not decode.
public enum NodeBudgetDecodeError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The document is JSON but does not fit the types. `path` names the
    /// offending value, such as "status.signals[0].id", and is empty at the root.
    case malformed(path: String, reason: String)
    /// The document's apiVersion is missing or is not the one this SDK reads.
    case unsupportedVersion
    /// The data is not JSON.
    case notJSON

    /// A one-line description.
    public var description: String {
        switch self {
        case let .malformed(path, reason):
            return "malformed NodeBudget at \(path.isEmpty ? "<root>" : path): \(reason)"
        case .unsupportedVersion:
            return "unsupported NodeBudget apiVersion, want \(K3smSDKVersion.nodeBudgetAPIVersion)"
        case .notJSON:
            return "the NodeBudget document is not JSON"
        }
    }

    init(_ error: DecodingError) {
        switch error {
        case let .keyNotFound(key, ctx):
            self = .malformed(path: Self.path(ctx.codingPath + [key]), reason: "missing required key")
        case let .valueNotFound(type, ctx):
            self = .malformed(path: Self.path(ctx.codingPath), reason: "null where a \(type) is required")
        case let .typeMismatch(type, ctx):
            self = .malformed(path: Self.path(ctx.codingPath), reason: "expected a \(type)")
        case let .dataCorrupted(ctx):
            self = .malformed(path: Self.path(ctx.codingPath), reason: ctx.debugDescription)
        @unknown default:
            self = .malformed(path: "", reason: String(describing: error))
        }
    }

    /// Spells a coding path as "a.b[2].c".
    static func path(_ keys: [any CodingKey]) -> String {
        var out = ""
        for key in keys {
            // An array index's key spells itself "Index <n>"; a dictionary
            // key that happens to be numeric does not.
            if let index = key.intValue, key.stringValue == "Index \(index)" {
                out += "[\(index)]"
            } else {
                out += out.isEmpty ? key.stringValue : "." + key.stringValue
            }
        }
        return out
    }
}
