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

/// The SDK's own version, with the page ABI and NodeBudget wire constants
/// the SDK reads.
public enum K3smSDKVersion {
    /// The major version.
    public static let major = 0
    /// The minor version.
    public static let minor = 0
    /// The patch version.
    public static let patch = 0
    /// The version as "major.minor.patch".
    public static let string = "0.0.0"
    /// The one page ABI major this SDK reads. An unknown major is an ABI mismatch.
    public static let pageABIMajor = 1
    /// The apiVersion of the NodeBudget custom resource this SDK reads.
    public static let nodeBudgetAPIVersion = "budget.k3sm.io/v1alpha1"
    /// The kind of a NodeBudget document.
    public static let nodeBudgetKind = "NodeBudget"
    /// The kind of a NodeBudgetList document.
    public static let nodeBudgetListKind = "NodeBudgetList"
}
