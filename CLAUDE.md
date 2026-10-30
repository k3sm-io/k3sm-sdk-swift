# k3sm Swift SDK

A Swift client for the k3sm node pressure and headroom API (SwiftPM package `K3smSDK`, one library
product of the same name). It is a leaf: it talks to a k3sm node over the API that node serves and
imports no code from the other k3sm repositories. It has no dependencies, and it has no edge back
to the k3sm macOS app or to k3sm: the app may depend on the SDK, never the reverse.

> User-facing behavior: `README.md`.

**The client API follows the reviewed design; add nothing ahead of it.** What exists: the Codable
NodeBudget status types under `Sources/K3smSDK/NodeBudget/` (parse-only, no I/O) and the budget page
reader under `Sources/K3smSDK/Page/` (`BudgetPage`, a read-only mapping read under the writer's
seqlock through the C11 primitives of the in-package `Sources/CK3smPage` target) and its change
notifier (`BudgetNotifier`, a shared `os_sync_wait_on_address` wait on the `notifyEpoch` word, a
kqueue doorbell when the producer provides one, and `changes()` over one dedicated thread).

## Layout
- **`Sources/K3smSDK/`**: the library. Everything public is reachable through `import K3smSDK`.
- **`Sources/CK3smPage/`**: the page reader's C11 seqlock primitives, imported internally by `K3smSDK`.
- **`Tests/K3smSDKTests/`**: Swift Testing tests (`@Test`), run by `swift test`.
- **`Tests/PageTestWriter/`, `Tests/CK3smTestWake/`**: test-only targets, not products: a stand-in
  page writer the notifier test runs as a second process, and the wake call it shares with the tests.
- **`hack/`**: the gate and its checks; `hack/testdata/` holds the dependency and fixture checks' red-path fixtures.

## Build / test
```sh
swift build
swift test
hack/ci.sh      # the full gate
```
- `hack/ci.sh` is the gate: no declared dependencies; `swift build` and `swift test`; a consumer
  package that depends on a git clone of the checkout by `.package(url: "file://...", revision:)`
  and builds; shellcheck; license headers; dormant workflows; the dependency check.
- Named stages run alone: `--reader` (the page fixtures' digests and the `BudgetPageReaderTests`
  suite), `--notifier` (the `BudgetNotifierTests` suite with `K3SM_SDK_INTEGRATION=1`, which
  enables the process-spawning test the unit and sanitizer runs skip), `--stress`, `--bench-rig`
  (placeholders that print "not yet implemented" until their items land), `--sanitize` (address, undefined, thread) and
  `--version-check` (`hack/verify-version.sh`: a `v*` tag on HEAD equals `K3smSDKVersion`) and
  `--nodebudget` (`hack/verify-fixtures.sh` and the golden-document gate test).
- Test fixtures copied from another repository are vendored byte for byte, each with a digest line
  in its directory's `FIXTURES.sha256`; `hack/verify-fixtures.sh` fails on a mismatch or on a file
  without a line.
- A consumer pins `.package(url:, revision: "<40-hex sha>") // vX.Y.Z`, never `from:`, a tag or a branch,
  and lists the revision in its own `deps.allow`.
- A caller that already runs inside a sandbox sets `K3SM_SWIFTPM_DISABLE_SANDBOX=1`: SwiftPM's own
  sandbox cannot nest inside another, so `ci.sh` then passes `--disable-sandbox`.
- With only the Command Line Tools, `swift test` needs the swift-testing macro plugin path;
  `hack/ci.sh` adds it.
- **No third-party dependencies, ever.** `hack/verify-deps.sh` (run by `ci.sh`) fails on any
  `.package(` not listed in `hack/deps.allow` with an exact revision, and the allow file is empty.

## Conventions
- **`swift-tools-version:6.0`, so Swift 6.0 is the minimum compiler** (`ci.sh` refuses an older one).
  Swift 6 language mode (strict concurrency), macOS 26 and later. Public types are `Sendable` where they can be.
- **A consumer needs no options.** `.package(url:revision:)` and `.product(name: "K3smSDK",
  package: "k3sm-sdk-swift")` give the library and build nothing else.
- Every `.swift` file starts with the Apache-2.0 header in `hack/boilerplate/boilerplate.swift.txt`
  (after the tools-version line in `Package.swift`); `hack/verify-boilerplate.sh` checks it. Shell
  files carry the two-line `Copyright` and `SPDX-License-Identifier` comment.
- Workflows under `.github/workflows/` stay fully commented out; `ci.sh` checks it.

## Commits
Conventional Commits per `CONTRIBUTING.md`. Scopes are the target directories, lowercased
(`k3smsdk`, `k3smsdktests`), or `hack` and `docs`. Sign off every commit (`git commit -s`).
