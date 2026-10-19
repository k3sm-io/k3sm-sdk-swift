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

import K3smSDK
import Testing

@Test("the version constants are 0.0.0")
func versionIsPinned() {
    #expect(K3smSDKVersion.major == 0)
    #expect(K3smSDKVersion.minor == 0)
    #expect(K3smSDKVersion.patch == 0)
}

@Test("the version string spells the three numbers")
func versionStringMatchesNumbers() {
    let want = "\(K3smSDKVersion.major).\(K3smSDKVersion.minor).\(K3smSDKVersion.patch)"
    #expect(K3smSDKVersion.string == want)
}

@Test("the page ABI major and the NodeBudget apiVersion are pinned")
func contractConstantsArePinned() {
    #expect(K3smSDKVersion.pageABIMajor == 1)
    #expect(K3smSDKVersion.nodeBudgetAPIVersion == "budget.k3sm.io/v1alpha1")
}
