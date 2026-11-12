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

/// The number of open descriptors in this process, probed with F_GETFD so the
/// count opens nothing of its own. The leak tests share one protocol: run a
/// round of the failing call as a warm-up, take this count, run more rounds,
/// take it again, and expect the two to be equal. The warm-up puts anything
/// opened lazily (a framework's first use, a thread) in the first count, and a
/// leak on a failing path grows the second by one per call. Equality holds
/// even with the other suites running in parallel (measured over repeated
/// runs of both leak suites together, with and without the process-spawning
/// notifier test), and the C++ SDK's `open_fd_count` is the same probe with
/// the same bar.
func openDescriptorCount() -> Int {
    (0..<Int32(min(getdtablesize(), 1 << 16))).reduce(0) { $0 + (fcntl($1, F_GETFD) >= 0 ? 1 : 0) }
}
