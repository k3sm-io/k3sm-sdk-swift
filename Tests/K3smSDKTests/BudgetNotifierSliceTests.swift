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

import Testing

@testable import K3smSDK

// The caps are spelled as literals, not read from the notifier's constants,
// so a changed cap fails here instead of moving the expectation with it.
private let doorbellCap: UInt64 = 100_000_000 // 100 ms
private let wordCap: UInt64 = 24 * 60 * 60 * 1_000_000_000 // 24 h
private let failedSleepCap: UInt64 = 10_000_000 // 10 ms

/// The remaining times each clamp is checked at: zero, below, at and above
/// its cap, and the largest remaining the type holds. `remaining` is a
/// UInt64, so there is no negative case.
private func cases(cap: UInt64) -> [(remaining: UInt64, want: UInt64)] {
    [(0, 0), (1, 1), (cap - 1, cap - 1), (cap, cap), (cap + 1, cap), (.max, cap)]
}

@Test("each wait slice is the remaining time clamped to its cap")
func waitSliceIsClamped() {
    for c in cases(cap: doorbellCap) {
        #expect(BudgetNotifier.doorbellWaitSlice(remaining: c.remaining) == c.want, "doorbell \(c.remaining)")
    }
    for c in cases(cap: wordCap) {
        #expect(BudgetNotifier.wordWaitSlice(remaining: c.remaining) == c.want, "word \(c.remaining)")
    }
    for c in cases(cap: failedSleepCap) {
        #expect(BudgetNotifier.failedWaitSleep(remaining: c.remaining) == c.want, "failed sleep \(c.remaining)")
    }
}

@Test("the caps are the documented ones")
func waitSliceCapsArePinned() {
    #expect(BudgetNotifier.doorbellSlice == .milliseconds(100))
    #expect(BudgetNotifier.maxWordWait == wordCap)
    #expect(BudgetNotifier.failedWordWaitSleep == failedSleepCap)
}
