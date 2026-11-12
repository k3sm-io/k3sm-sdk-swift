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

/// The most the open-descriptor count may grow between the two probes of a
/// leak test before the test calls it a leak.
let descriptorCountSlack = 64

/// The number of open descriptors in this process, probed with F_GETFD so the
/// count opens nothing of its own. The leak tests share one protocol: run a
/// round of the failing call as a warm-up, take this count, run two more
/// rounds, take it again, and expect growth under `descriptorCountSlack`. The
/// warm-up puts anything opened lazily (a framework's first use, a thread) in
/// the first count. The probe counts the whole process and swift-testing runs
/// other suites in parallel (Process and Pipe users, a FIFO opener thread,
/// kqueue doorbells), which hold descriptors briefly, so exact equality is
/// not safe here. A leak on a failing path grows the count by one per call,
/// and each test makes 1200 failing calls in the measured rounds (two rounds
/// of 300 iterations, two calls each), so any leak clears the slack by far.
/// The C++ SDK's `open_fd_count` asserts equality because its tests run
/// sequentially, one executable per process.
func openDescriptorCount() -> Int {
    (0..<Int32(min(getdtablesize(), 1 << 16))).reduce(0) { $0 + (fcntl($1, F_GETFD) >= 0 ? 1 : 0) }
}
