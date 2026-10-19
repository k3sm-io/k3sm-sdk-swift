# k3sm Swift SDK

A Swift client for the k3sm node pressure and headroom API (SwiftPM package `K3smSDK`, one library
product of the same name). It is a leaf: it talks to a k3sm node over the API that node serves and
imports no code from the other k3sm repositories. It has no dependencies, and it has no edge back
to the k3sm macOS app or to k3sm: the app may depend on the SDK, never the reverse.

> User-facing behavior: `README.md`.

**The client API is under design review.** Until that design lands, the repository carries only the
package, test and gate scaffolding and `Sources/K3smSDK/Version.swift`. Do not add client code ahead
of the reviewed design.

## Layout
- **`Sources/K3smSDK/`**: the library. Everything public is reachable through `import K3smSDK`.
- **`Tests/K3smSDKTests/`**: Swift Testing tests (`@Test`), run by `swift test`.
- **`hack/`**: the gate and its checks; `hack/testdata/` holds the dependency check's fixtures.

## Build / test
```sh
swift build
swift test
hack/ci.sh      # the full gate
```
- `hack/ci.sh` is the gate: no declared dependencies; `swift build` and `swift test`; a consumer
  package that depends on a git clone of the checkout by `.package(url: "file://...", revision:)`
  and builds; shellcheck; license headers; dormant workflows; the dependency check.
- A caller that already runs inside a sandbox sets `K3SM_SWIFTPM_DISABLE_SANDBOX=1`: SwiftPM's own
  sandbox cannot nest inside another, so `ci.sh` then passes `--disable-sandbox`.
- With only the Command Line Tools, `swift test` needs the swift-testing macro plugin path;
  `hack/ci.sh` adds it.
- **No third-party dependencies, ever.** `hack/verify-deps.sh` (run by `ci.sh`) fails on any
  `.package(` not listed in `hack/deps.allow` with an exact revision, and the allow file is empty.

## Conventions
- **Swift 6 language mode, macOS 26 and later.** Public types are `Sendable` where they can be.
- **A consumer needs no options.** `.package(url:revision:)` and `.product(name: "K3smSDK",
  package: "k3sm-sdk-swift")` give the library and build nothing else.
- Every `.swift` file starts with the Apache-2.0 header in `hack/boilerplate/boilerplate.swift.txt`
  (after the tools-version line in `Package.swift`); `hack/verify-boilerplate.sh` checks it. Shell
  files carry the two-line `Copyright` and `SPDX-License-Identifier` comment.
- Workflows under `.github/workflows/` stay fully commented out; `ci.sh` checks it.

## Commits
Conventional Commits per `CONTRIBUTING.md`. Scopes are the target directories, lowercased
(`k3smsdk`, `k3smsdktests`), or `hack` and `docs`. Sign off every commit (`git commit -s`).
