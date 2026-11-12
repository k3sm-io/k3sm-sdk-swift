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

import Darwin
import Foundation
@testable import K3smSDK
import Testing

/// A failed address wait on the epoch word sleeps before the word is polled
/// again, so the wait neither spins nor misses a bump.
@Suite struct BudgetNotifierTestsFailedWordWait {
    @Test func failedWordWaitSleepsAndRetriesUntilTheTimeout() throws {
        let w = try WritablePage()
        let page = try BudgetPage.open(path: w.path)
        let from = page.loadNotifyEpoch()
        var calls = 0
        var got: UInt64? = 7
        let cpuBefore = threadCPUNanoseconds()
        let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        got = BudgetNotifier.waitForChange(
            page, doorbell: nil, from: from, timeout: .milliseconds(300)
        ) { _, _, _, _ in
            calls += 1
            return EINVAL
        }
        let elapsedNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start
        let cpu = threadCPUNanoseconds() - cpuBefore
        #expect(got == nil)
        #expect(elapsedNs >= 290_000_000, "returned after \(elapsedNs / 1_000_000) ms")
        #expect(elapsedNs < 2_000_000_000, "returned after \(elapsedNs / 1_000_000) ms")
        #expect((3...100).contains(calls), "\(calls) word waits in a 300 ms wait")
        #expect(cpu < 150_000_000, "the wait spun: \(cpu / 1_000_000) ms of CPU in a 300 ms wait")
    }

    @Test func failedWordWaitStillSeesAnEpochBump() throws {
        let w = try WritablePage()
        let page = try BudgetPage.open(path: w.path)
        let from = page.loadNotifyEpoch()
        var calls = 0
        let got = BudgetNotifier.waitForChange(
            page, doorbell: nil, from: from, timeout: .seconds(2)
        ) { _, _, _, _ in
            calls += 1
            if calls == 3 { w.bumpEpoch() }
            return EINVAL
        }
        #expect(got == from &+ 1)
        #expect(calls == 3)
    }
}

/// The calling thread's CPU time in nanoseconds.
private func threadCPUNanoseconds() -> UInt64 {
    var ts = timespec()
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
    return UInt64(ts.tv_sec) * 1_000_000_000 + UInt64(ts.tv_nsec)
}
