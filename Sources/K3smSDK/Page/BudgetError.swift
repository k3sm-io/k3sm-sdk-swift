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

/// Why the budget page could not be opened or read. The cases are the page
/// reader contract's error names, the same in every k3sm SDK.
public enum BudgetError: Error, Equatable, Sendable, CustomStringConvertible {
    /// There is no page at the path, or no access to it. `errno` tells
    /// ENOENT (no page) from EACCES (no access) and from any other failure to
    /// open or map the file.
    case notFound(errno: Int32)
    /// The file is not a page this SDK reads: bad magic, an unknown ABI
    /// major, an unexpected header size, or a code its tables do not hold.
    case abiMismatch
    /// The file is shorter than its header and body, or its body is shorter
    /// than the minor this SDK knows.
    case truncated
    /// The header is well formed but a field is outside its domain, such as
    /// a node name longer than 253 bytes.
    case corrupt
    /// No stable read: the writer kept the page busy for every attempt.
    case torn
    /// The page has not been published for more than three writer periods.
    case stale

    /// The contract name of the error, as the apis page manifest spells it.
    var contractName: String {
        switch self {
        case .notFound: return "notFound"
        case .abiMismatch: return "abiMismatch"
        case .truncated: return "truncated"
        case .corrupt: return "corrupt"
        case .torn: return "torn"
        case .stale: return "stale"
        }
    }

    /// A one-line description.
    public var description: String {
        switch self {
        case let .notFound(errno): return "budget page not found (errno \(errno))"
        case .abiMismatch: return "budget page ABI mismatch"
        case .truncated: return "budget page truncated"
        case .corrupt: return "budget page corrupt"
        case .torn: return "budget page read torn"
        case .stale: return "budget page stale"
        }
    }
}
