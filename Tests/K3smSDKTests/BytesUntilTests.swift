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

// A byte signal with no value and no rungs; each test sets what it needs.
private func byteSignal(_ id: NodeBudget.SignalID) throws -> NodeBudget.Signal {
    let json = #"{"id":"\#(id.rawValue)","unit":"bytes"}"#
    return try JSONDecoder().decode(NodeBudget.Signal.self, from: Data(json.utf8))
}

// A snapshot that carries only the given signals.
private func snapshot(_ signals: [NodeBudget.Signal]) throws -> BudgetSnapshot {
    return BudgetSnapshot(
        seq: 2, notifyEpoch: 0, generation: 1, writerPeriodSeconds: 1, observedAt: 0,
        platform: .darwin, nodeName: "node",
        capacity: NodeBudget.Capacity(),
        level: .ok, darwin: nil, linux: nil, signals: signals, admit: true,
        admitReasonSignal: nil, evictDeadline: nil,
        killMode: .init(mode: nil, armed: false, armingEpisodes: 0, reason: nil),
        recommendation: NodeBudget.Recommendation(),
        counters: [])
}

@Suite struct BytesUntilTests {
    @Test func everyRungMapsToItsOwnThreshold() throws {
        // memory.available falls toward its rungs; each rung gets its own
        // threshold, so a rung read from another rung's field is caught.
        var sig = try byteSignal(.memoryAvailable)
        sig.value = 10_000
        sig.warnThreshold = 5_000
        sig.evictSoftThreshold = 4_000
        sig.evictHardThreshold = 3_000
        sig.admitStopThreshold = 2_000
        sig.criticalThreshold = 1_000
        let s = try snapshot([sig])
        let want: [(rung: BudgetSnapshot.Rung, distance: Int64)] = [
            (.warn, 5_000),
            (.evictSoft, 6_000),
            (.evictHard, 7_000),
            (.admitStop, 8_000),
            (.critical, 9_000),
        ]
        #expect(Set(want.map(\.rung)) == Set(BudgetSnapshot.Rung.allCases))
        for w in want {
            #expect(s.bytesUntil(signal: .memoryAvailable, rung: w.rung) == w.distance, "\(w.rung)")
        }
    }

    @Test func zeroAtOrPastARung() throws {
        // memory.swap rises toward its rungs.
        var swap = try byteSignal(.memorySwap)
        swap.warnThreshold = 1_000
        var avail = try byteSignal(.memoryAvailable)
        avail.warnThreshold = 1_000

        // Past the rung: a rising value above its threshold.
        swap.value = 1_500
        #expect(try snapshot([swap]).bytesUntil(signal: .memorySwap, rung: .warn) == 0)
        // At the rung, rising.
        swap.value = 1_000
        #expect(try snapshot([swap]).bytesUntil(signal: .memorySwap, rung: .warn) == 0)
        // At the rung, falling.
        avail.value = 1_000
        #expect(try snapshot([avail]).bytesUntil(signal: .memoryAvailable, rung: .warn) == 0)
    }

    @Test func absentValueAndExtremes() throws {
        // An absent value gives no distance, even with the rung present.
        var avail = try byteSignal(.memoryAvailable)
        avail.warnThreshold = 1_000
        #expect(try snapshot([avail]).bytesUntil(signal: .memoryAvailable, rung: .warn) == nil)

        // A negative threshold is clamped to 0, so the largest value is the
        // whole distance on a falling signal, with no overflow.
        avail.value = .max
        avail.warnThreshold = -1
        #expect(try snapshot([avail]).bytesUntil(signal: .memoryAvailable, rung: .warn) == .max)
        avail.warnThreshold = .min + 1
        #expect(try snapshot([avail]).bytesUntil(signal: .memoryAvailable, rung: .warn) == .max)

        // The same pair on a rising signal is past the rung.
        var swap = try byteSignal(.memorySwap)
        swap.value = .max
        swap.warnThreshold = -1
        #expect(try snapshot([swap]).bytesUntil(signal: .memorySwap, rung: .warn) == 0)
        swap.warnThreshold = .min + 1
        #expect(try snapshot([swap]).bytesUntil(signal: .memorySwap, rung: .warn) == 0)
    }
}
