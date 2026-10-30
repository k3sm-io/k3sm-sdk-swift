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

// A stand-in page writer in its own process, for the notifier tests. It maps
// the page file named by its one argument read-write and publishes under the
// seqlock, one command per stdin line, answering each with one stdout line:
//
//   seq     publish a new sample with no notify-worthy change: seq advances,
//           notifyEpoch does not, and waiters are still woken, as a careless
//           writer might; a reader must not report it as a change
//   epoch   publish a level change: seq advances, then notifyEpoch, then
//           waiters are woken
//   quiet   bump notifyEpoch without waking anyone (a reader sees it by poll)
//   quit    exit
//
// The answer is "ok <seq> <notifyEpoch>" after the publish.

import CK3smTestWake
import Darwin
import Synchronization

let seqOffset = 64
let notifyEpochOffset = 128
let observedAtOffset = 208
let levelOffset = 552

func fail(_ message: String) -> Never {
    fputs("PageTestWriter: \(message)\n", stderr)
    exit(1)
}

guard CommandLine.arguments.count == 2 else { fail("usage: PageTestWriter <page>") }
let fd = open(CommandLine.arguments[1], O_RDWR)
guard fd >= 0 else { fail("open: errno \(errno)") }
guard let m = mmap(nil, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0), m != MAP_FAILED else {
    fail("mmap: errno \(errno)")
}

func word(_ offset: Int) -> UnsafeMutablePointer<Atomic<UInt64>> {
    (m + offset).assumingMemoryBound(to: Atomic<UInt64>.self)
}

func load(_ offset: Int) -> UInt64 { word(offset).pointee.load(ordering: .acquiring) }
func store(_ offset: Int, _ value: UInt64) { word(offset).pointee.store(value, ordering: .releasing) }

/// One seqlock publish: seq odd, the body, seq even.
func publish(level: UInt64?) {
    let seq = load(seqOffset)
    store(seqOffset, seq &+ 1)
    var ts = timespec()
    clock_gettime(CLOCK_REALTIME, &ts)
    store(observedAtOffset, UInt64(bitPattern: Int64(ts.tv_sec)))
    if let level { store(levelOffset, level) }
    store(seqOffset, seq &+ 2)
}

func wake() {
    let rc = ck3sm_test_wake_all(m + notifyEpochOffset)
    guard rc == 0 || rc == ENOENT else { fail("wake: errno \(rc)") }
}

while let line = readLine() {
    switch line {
    case "seq":
        publish(level: nil)
        wake()
    case "epoch":
        // Alternate warn and critical, so every bump is a real level change.
        publish(level: load(levelOffset) == 2 ? 3 : 2)
        store(notifyEpochOffset, load(notifyEpochOffset) &+ 1)
        wake()
    case "quiet":
        store(notifyEpochOffset, load(notifyEpochOffset) &+ 1)
    case "quit":
        exit(0)
    default:
        fail("unknown command \(line)")
    }
    print("ok \(load(seqOffset)) \(load(notifyEpochOffset))")
    fflush(stdout)
}
