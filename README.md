# k3sm Swift SDK

A Swift client for the node pressure and headroom API of
[k3sm](https://k3sm.io), the macOS-native Kubernetes distribution for Apple
Silicon. It is for Swift programs that run on a k3sm node and need to react to
that node's resource pressure and headroom.

**Status: the client API is being designed, and two parts have shipped.**
The package carries the `NodeBudget` status types (`Sources/K3smSDK/NodeBudget`,
Codable and parse-only, no I/O) and `BudgetPage`
(`Sources/K3smSDK/Page`), a read-only mapping of the node budget page that
reads a stable `BudgetSnapshot` under the writer's seqlock and reports
failures as `BudgetError`. The change notifier and the rest of the client are
not here yet.

## Use it

The SDK is a SwiftPM package with one library product, `K3smSDK`, for macOS 26
and later. Pin it to the exact 40-character revision of a release tag, with the tag in a
comment. Never use `from:`, an exact tag or a branch:

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

Read the node budget page. `BudgetPage.defaultPagePath` is the page's location
for the platform the SDK is built for:

```swift
import K3smSDK

do {
    let page = try BudgetPage.open(path: BudgetPage.defaultPagePath)
    switch page.read() {
    case .success(let snapshot):
        print("admit:", snapshot.admitOK)
        if let room = snapshot.bytesUntil(signal: .memoryCompressor, rung: .admitStop) {
            print("bytes until admit-stop:", room)
        }
    case .failure(let error):
        print("no stable read:", error)
    }
} catch {
    print("cannot open the page:", error)
}
```

## Build and test

```sh
swift build
swift test
hack/ci.sh          # the full gate
hack/ci.sh --sanitize   # only the address, undefined-behavior and thread sanitizer runs
```

Requirements: Swift 6.0 or later as the minimum compiler (the package declares
`swift-tools-version:6.0` and builds in the Swift 6 language mode; the Xcode
Command Line Tools are enough) on macOS 26 or later. The SDK depends on nothing outside the toolchain.

## Contributing

See `CONTRIBUTING.md`. Every commit is signed off for the Developer
Certificate of Origin (`git commit -s`), and commit subjects follow
Conventional Commits.

## License

Apache-2.0, see `LICENSE`.
