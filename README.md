# k3sm Swift SDK

A Swift client for the node pressure and headroom API of
[k3sm](https://k3sm.io), the macOS-native Kubernetes distribution for Apple
Silicon. It is for Swift programs that run on a k3sm node and need to react to
that node's resource pressure and headroom.

**Status: the client API is being designed, and three parts have shipped.**
The package carries the `NodeBudget` status types (`Sources/K3smSDK/NodeBudget`,
Codable and parse-only, no I/O) and `BudgetPage`
(`Sources/K3smSDK/Page`), a read-only mapping of the node budget page that
reads a stable `BudgetSnapshot` under the writer's seqlock and reports
failures as `BudgetError`, and `BudgetNotifier`, which tells a reader when the
page's level, admit, a threshold or the generation changed. The rest of the
client is not here yet.

## Use it

The SDK is a SwiftPM package with one library product, `K3smSDK`, for macOS 26
and later. Pin it to the exact 40-character revision of a release tag, with the
tag in a comment. Never use `from:`, an exact tag or a branch. The revision and
the `v1.0.0` tag below are placeholders: the package version is 0.0.0 and there
is no release yet.

```swift
dependencies: [
    .package(url: "https://github.com/k3sm-io/k3sm-sdk-swift.git", revision: "<40-hex sha>"), // v1.0.0
],
targets: [
    .target(name: "YourTarget", dependencies: [
        .product(name: "K3smSDK", package: "k3sm-sdk-swift"),
    ]),
]
```

```swift
import K3smSDK

print(K3smSDKVersion.string)
```

Read the node budget page. The package manifest lists macOS 26.0 as its only
platform, and `BudgetPage.defaultPagePath` is the page's location there.
`BudgetPage.darwinPagePath` is where a native Darwin pod finds the page, and
`defaultPagePath` is that path on this platform.
`BudgetPage.linuxPagePath` is where a reader on Linux finds the page (a VM
guest, or a pod on a Linux producer's node); readers on Linux use the C++ SDK.
An opened `BudgetPage` reports its `path`, `abiMajor`, `abiMinor`,
`headerSize` and `bodySize`.
`open` maps the page and checks its header, and throws `notFound` (with the
errno), `truncated` or `abiMismatch`.
`read()` reports `corrupt`, `torn` and `stale`, and can also report
`abiMismatch` or `truncated` if a writer takes the page over. A page is stale
when its observation is more than three writer periods old:

```swift
import K3smSDK

do {
    let page = try BudgetPage.open(path: BudgetPage.defaultPagePath)
    switch page.read() {
    case .success(let snapshot):
        print("admit:", snapshot.admitOK)
        if let room = snapshot.bytesUntil(signal: .memoryAvailable, rung: .admitStop) {
            print("bytes until admit-stop:", room)
        }
        print("slots of 512 MiB:", snapshot.batchSlots(slotBytes: 512 * 1024 * 1024))
    case .failure(let error):
        print("no stable read:", error)
    }
} catch {
    print("cannot open the page:", error)
}
```

`bytesUntil(signal:rung:)` returns nil when the page has no such signal, when
the signal is not measured in bytes (a permille or a count), or when the value
or the rung's threshold is absent. It treats a negative value or threshold
as 0. `batchSlots(slotBytes:)` returns an `Int64`: how many slots of that size
fit in the recommendation's safe additional bytes. It returns 0 when the node
does not admit, when the page carries no positive recommendation, or when the
slot size is not positive.

Decode a NodeBudget document you already hold as JSON. `NodeBudgetDecoder` does
no I/O. `decodeBudget(_:)` reads one NodeBudget, `decodeList(_:)` a
NodeBudgetList, and `decodeStatus(_:)` a bare status object, which carries no
apiVersion or kind. Each takes `Data` and throws `NodeBudgetDecodeError`:
`malformed(path:reason:)`, `unsupportedVersion`, `unsupportedKind(_:)` or
`notJSON`.

```swift
import Foundation
import K3smSDK

// jsonData is the NodeBudget JSON you already hold, as Data.
do {
    let budget = try NodeBudgetDecoder.decodeBudget(jsonData)
    print("status:", budget.status as Any)
} catch {
    print("cannot decode:", error)
}
```

Follow changes. The writer bumps the page's `notifyEpoch` word only when the
level, admit, a threshold or the generation changes. `BudgetNotifier` wakes on
that word across processes when no doorbell file is given. With a doorbell
file, the notifier waits on the doorbell only, in slices of at most 100 ms,
and reads the word between slices, so a missed doorbell write delays a change
by at most that. Without a doorbell file, one wait on the word is cut into
slices of at most 24 hours, and after a failed wait the notifier sleeps 10 ms
and checks the word again. With a doorbell file, after a failed doorbell wait
the notifier stops using the doorbell and checks the word every 100 ms. It
never switches from waiting on the word to waiting on the doorbell, or the
reverse. The C++ SDK chooses its wake source differently; its README says how.
`changes()` yields the current read, then one read per change, from one
thread of its own that ends when the stream is cancelled. `changes()` opens
its own doorbell from the same path, and if that open fails its thread waits
on the word instead. A read that is `torn` or `stale` is read again one writer
period later, and only that second result is yielded. A writer that goes silent
bumps no epoch, so `changes()` also yields the `stale` error once the last
snapshot is older than the page's staleness rule allows, and the next fresh read
after that. `poll()` never blocks. `wait(timeout:)` blocks its thread, so never
call it from Swift concurrency. The `doorbellPath:` parameter of the
`BudgetNotifier` init is optional: it is the path of the doorbell file the
producer provides, which the notifier opens for kqueue, and the init throws
`BudgetError.notFound` if it cannot:

```swift
let notifier = try BudgetNotifier(try BudgetPage.open(path: BudgetPage.defaultPagePath))
for await read in notifier.changes() {
    if case .success(let snapshot) = read {
        print("level:", snapshot.level, "admit:", snapshot.admitOK)
    }
}
```

`BudgetNotifier.notifyEpoch` returns the last epoch the notifier reported, or
the epoch at `init` before it has reported one.

A notifier starts from the epoch the page holds at `init`, so a change that
lands after you read a snapshot and before you create the notifier would be
taken as already seen. Seed it with the snapshot's `notifyEpoch` and the next
`poll()` or `wait(timeout:)` reports that change. Unlike the C++ SDK's
`seed`, which must be called before the first poll or wait on the waiting
thread, this one is safe to call from any thread. Seeding does not affect a
`changes()` stream, which tracks its own epoch:

```swift
let page = try BudgetPage.open(path: BudgetPage.defaultPagePath)
let snapshot = try page.read().get()
let notifier = try BudgetNotifier(page)
notifier.seed(snapshot.notifyEpoch)
if let epoch = notifier.poll() {
    print("changed since the snapshot, now at epoch", epoch)
}
```

## Build and test

```sh
swift build
swift test
hack/ci.sh          # the full gate
hack/ci.sh --sanitize   # only the address, undefined-behavior and thread sanitizer runs
hack/ci.sh --notifier   # only the notifier tests, the cross-process one included
hack/ci.sh --reader     # only the page reader tests and their fixtures
hack/ci.sh --nodebudget # only the NodeBudget fixture checks and test
hack/ci.sh --version-check # only the version constants against a release tag on HEAD
```

The full gate checks that the package declares no dependencies, builds, runs the
tests, builds a consumer package that pins this checkout by revision, runs
shellcheck, checks the license headers and that the workflows are dormant, runs
the supply-chain check and the version check, runs the tests under the address,
undefined-behavior and thread sanitizers, and then the NodeBudget, page reader
and notifier stages.

Requirements: Swift 6.0 or later as the minimum compiler (the package declares
`swift-tools-version:6.0` and builds in the Swift 6 language mode; the Xcode
Command Line Tools are enough) on macOS 26 or later. The SDK depends on nothing
outside the toolchain. Unlike the plain build, every `hack/ci.sh` run also
needs the toolchain's clang UBSan runtime, and the full gate needs `shellcheck`
on your `PATH`.

## Contributing

See `CONTRIBUTING.md`. Every commit is signed off for the Developer
Certificate of Origin (`git commit -s`), and commit subjects follow
Conventional Commits.

## License

Apache-2.0, see `LICENSE`.
