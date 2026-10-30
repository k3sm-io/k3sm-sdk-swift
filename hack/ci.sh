#!/usr/bin/env bash
# Copyright The k3sm Authors.
# SPDX-License-Identifier: Apache-2.0
#
# ci.sh -- the k3sm Swift SDK's gate. Run from anywhere; it works on a lone clone.
#
#   0. the package declares no dependencies
#   1. swift build
#   2. swift test (the version constants are pinned)
#   3. build a consumer package that depends on a git clone of this checkout
#      by .package(url: "file://...", revision: "<sha>") and imports K3smSDK
#   4. shellcheck over every hack/**/*.sh
#   5. every .swift file carries the Apache-2.0 header
#   6. every file under .github/workflows/ is dormant (fully commented out)
#   7. the dependency supply-chain check: its self-test, then the live tree
#   8. the version constants against a v* tag on HEAD (hack/verify-version.sh)
#   9. swift test under the address, undefined-behavior and thread sanitizers
#  10. the NodeBudget status types: the vendored goldens match their digests
#      (hack/verify-fixtures.sh, after its self-test) and the gate test
#      decodes and re-encodes them key for key
#  11. the budget page reader: the vendored page fixtures match their
#      digests and the reader tests decode the golden pages, give each
#      negative page its manifest error and turn a scripted torn read into
#      torn (they also run under the sanitizers in stage 9)
#  12. the change notifier (integration): BudgetNotifierTests with the
#      process-spawning test enabled, in which a writer process bumps
#      notifyEpoch and a reader here wakes, and a seq-only change with a wake
#      is not reported
#
# A stage name as the first argument runs that stage alone: --reader,
# --sanitize, --version-check, --nodebudget, --notifier, and --stress,
# --bench-rig (placeholders until their items land).
#
# K3SM_SWIFTPM_DISABLE_SANDBOX=1 passes --disable-sandbox to every swift
# package, build and test run. SwiftPM applies its own sandbox when it compiles
# the manifest and builds, and a process already inside a sandbox cannot apply
# another one (sandbox_apply: Operation not permitted). A sandboxed caller sets
# this to turn off the inner sandbox and keep its own. Unset, nothing changes.
set -euo pipefail
cd "$(dirname "$0")/.."
stage="${1:-}"
case "$stage" in
	--stress|--bench-rig)
		echo "==> ${stage#--}"
		echo "    not yet implemented"
		exit 0 ;;
	""|--reader|--sanitize|--version-check|--nodebudget|--notifier) ;;
	*) echo "usage: hack/ci.sh [--reader|--sanitize|--version-check|--nodebudget|--notifier|--stress|--bench-rig]"; exit 2 ;;
esac
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

for tool in swift git; do
	command -v "$tool" >/dev/null || { echo "FAIL: $tool is not installed"; exit 1; }
done

# swift-tools-version 6.0 makes Swift 6.0 the minimum compiler.
swiftver="$(swift --version 2>&1 | sed -n 's/.*Swift version \([0-9]\{1,\}\).*/\1/p' | head -n 1)"
[ -n "$swiftver" ] && [ "$swiftver" -ge 6 ] \
	|| { echo "FAIL: Swift 6.0 or later is required (found: ${swiftver:-unknown})"; exit 1; }

SWIFT_FLAGS=()
if [ "${K3SM_SWIFTPM_DISABLE_SANDBOX:-}" = 1 ]; then
	SWIFT_FLAGS=(--disable-sandbox)
fi
# The Command Line Tools ship the swift-testing macro plugin in a directory
# SwiftPM does not search on its own; point the compiler at it. A full Xcode
# toolchain finds it without help, so this applies only when the plugin exists.
TEST_FLAGS=()
devdir="$(xcode-select -p 2>/dev/null || true)"
plugdir="$devdir/usr/lib/swift/host/plugins/testing"
if [ -n "$devdir" ] && [ -f "$plugdir/libTestingMacros.dylib" ]; then
	TEST_FLAGS=(-Xswiftc -plugin-path -Xswiftc "$plugdir")
fi

# The C target (CK3smPage) is compiled with -fsanitize=undefined under
# --sanitize=undefined, but swiftc, which links the test bundle, does not link
# clang's UBSan runtime, so the link fails on the __ubsan_handle_* symbols.
# Link the toolchain's own runtime explicitly; it ships with clang.
UBSAN_FLAGS=()
ubsan_dir="$(xcrun clang -print-resource-dir 2>/dev/null)/lib/darwin"
ubsan_lib="$ubsan_dir/libclang_rt.ubsan_osx_dynamic.dylib"
[ -f "$ubsan_lib" ] || { echo "FAIL: the clang UBSan runtime is missing ($ubsan_lib)"; exit 1; }
UBSAN_FLAGS=(-Xlinker "$ubsan_lib" -Xlinker -rpath -Xlinker "$ubsan_dir")

run_sanitizers() {
	echo "==> swift test --sanitize=address,undefined (ASan, UBSan)"
	swift test ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} ${TEST_FLAGS[@]+"${TEST_FLAGS[@]}"} --sanitize=address
	swift test ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} ${TEST_FLAGS[@]+"${TEST_FLAGS[@]}"} --sanitize=undefined \
		"${UBSAN_FLAGS[@]}"
	echo "==> swift test --sanitize=thread (TSan)"
	swift test ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} ${TEST_FLAGS[@]+"${TEST_FLAGS[@]}"} --sanitize=thread
}

run_version_check() {
	echo "==> version constants (hack/verify-version.sh)"
	bash hack/verify-version.sh
}

run_nodebudget() {
	echo "==> NodeBudget fixtures and status types (hack/verify-fixtures.sh)"
	bash hack/verify-fixtures.sh --self-test
	bash hack/verify-fixtures.sh
	swift test ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} ${TEST_FLAGS[@]+"${TEST_FLAGS[@]}"} \
		--filter statusTypesCoverGoldenNodeBudgetDocuments
}

run_notifier() {
	echo "==> change notifier (BudgetNotifierTests, integration)"
	K3SM_SDK_INTEGRATION=1 swift test ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} ${TEST_FLAGS[@]+"${TEST_FLAGS[@]}"} \
		--filter BudgetNotifierTests
}

run_reader() {
	echo "==> budget page reader (hack/verify-fixtures.sh, BudgetPageReaderTests)"
	bash hack/verify-fixtures.sh --self-test
	bash hack/verify-fixtures.sh "$PWD/Tests/K3smSDKTests/Fixtures/page"
	swift test ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} ${TEST_FLAGS[@]+"${TEST_FLAGS[@]}"} \
		--filter BudgetPageReaderTests
}

case "$stage" in
	--sanitize) run_sanitizers; exit 0 ;;
	--version-check) run_version_check; exit 0 ;;
	--nodebudget) run_nodebudget; exit 0 ;;
	--reader) run_reader; exit 0 ;;
	--notifier) run_notifier; exit 0 ;;
esac

echo "==> no third-party dependencies"
# The package depends on nothing outside the toolchain, which is also why there
# is no Package.resolved to commit: SwiftPM writes one only when it has pins.
# ${arr[@]+"${arr[@]}"} expands to nothing for an empty array; macOS bash 3.2
# treats a bare "${arr[@]}" on an empty array as unbound under set -u.
deps="$(swift package ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} show-dependencies 2>&1)"
printf '%s\n' "$deps" | grep -q '^No external dependencies found' \
	|| { echo "FAIL: the package must not declare dependencies:"; printf '%s\n' "$deps"; exit 1; }
[ ! -e Package.resolved ] || grep -q '"pins" : \[\s*\]' Package.resolved \
	|| { echo "FAIL: Package.resolved carries pins"; exit 1; }
echo "    ok"

echo "==> swift build"
swift build ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"}

echo "==> swift test"
swift test ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} ${TEST_FLAGS[@]+"${TEST_FLAGS[@]}"}

echo "==> a consumer pinning this checkout by revision"
# A git repository holding this checkout's files as they are (tracked and
# untracked, minus ignored ones), served over file://, stands in for the
# GitHub repository, so the gate checks the tree it runs on. The directory is
# named like the repository, so the package identity is the one a consumer of
# the GitHub URL sees.
src="$tmp/k3sm-sdk-swift"
mkdir -p "$src"
git ls-files -co --exclude-standard -z | while IFS= read -r -d '' f; do
	[ -f "$f" ] || continue
	mkdir -p "$src/$(dirname "$f")"; cp -p "$f" "$src/$f"
done
git -C "$src" init -q
git -C "$src" add -A
git -C "$src" -c user.name=ci -c user.email=ci@invalid -c commit.gpgsign=false commit -q -m snapshot
rev="$(git -C "$src" rev-parse HEAD)"
consumer="$tmp/consumer"
mkdir -p "$consumer/Sources/Consumer"
cat > "$consumer/Package.swift" <<SWIFT
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Consumer",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "file://$src", revision: "$rev"),
    ],
    targets: [
        .executableTarget(
            name: "Consumer",
            dependencies: [.product(name: "K3smSDK", package: "k3sm-sdk-swift")]
        ),
    ]
)
SWIFT
cat > "$consumer/Sources/Consumer/main.swift" <<'SWIFT'
import K3smSDK

let want = "\(K3smSDKVersion.major).\(K3smSDKVersion.minor).\(K3smSDKVersion.patch)"
if K3smSDKVersion.string != want {
    fatalError("K3smSDKVersion.string is \(K3smSDKVersion.string), want \(want)")
}
print("consumer: K3smSDK \(K3smSDKVersion.string)")
SWIFT
# The shared dependency cache is turned off and the cache path kept in the
# temp dir, so the gate writes nothing outside it.
swift build ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} --package-path "$consumer" \
	--disable-dependency-cache --cache-path "$tmp/cache" > "$tmp/consumer.log" 2>&1 \
	|| { cat "$tmp/consumer.log"; echo "FAIL: the consumer package did not build"; exit 1; }
grep -q "$rev" "$consumer/Package.resolved" \
	|| { echo "FAIL: the consumer did not resolve the SDK at $rev"; exit 1; }
"$consumer/.build/debug/Consumer" || { echo "FAIL: the consumer exited non-zero"; exit 1; }
echo "    ok"

echo "==> shellcheck (hack/**/*.sh)"
command -v shellcheck >/dev/null || { echo "FAIL: shellcheck is not installed"; exit 1; }
find hack -name '*.sh' -not -path '*/testdata/*' -print0 | xargs -0 shellcheck
echo "    ok"

echo "==> license headers (.swift)"
bash hack/verify-boilerplate.sh --self-test
bash hack/verify-boilerplate.sh

echo "==> workflows dormant (.github/workflows)"
# A workflow file is dormant iff it has no line that is neither blank nor a
# comment. Every file counts, whatever its name or extension. Deliberately
# strict: a stray '---' or a byte-order mark makes a file active.
active=0
if [ -d .github/workflows ]; then
	while IFS= read -r -d '' f; do
		if grep -qEv '^[[:space:]]*(#|$)' "$f"; then
			echo "    ACTIVE: $f"; active=1
		fi
	done < <(find .github/workflows -type f -print0)
fi
[ "$active" = 0 ] || { echo "FAIL: workflows must stay fully commented out"; exit 1; }
# Red-path check, so the predicate above cannot pass vacuously.
printf '# off\non: push\n' > "$tmp/active.yml"
printf '# off\n\n  # still off\n' > "$tmp/dormant.yml"
grep -qEv '^[[:space:]]*(#|$)' "$tmp/active.yml" || { echo "FAIL: predicate missed an active file"; exit 1; }
! grep -qEv '^[[:space:]]*(#|$)' "$tmp/dormant.yml" || { echo "FAIL: predicate flagged a dormant file"; exit 1; }
echo "    ok"

echo "==> dependency supply-chain (hack/verify-deps.sh)"
bash hack/verify-deps.sh --self-test
bash hack/verify-deps.sh

run_version_check

run_sanitizers

run_nodebudget

run_reader

run_notifier

echo "==> placeholder stages (--stress --bench-rig)"
for st in --stress --bench-rig; do
	bash hack/ci.sh "$st" | sed 's/^/    /'
done

echo "k3sm-sdk-swift ci: green"
