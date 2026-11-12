#!/usr/bin/env bash
# Copyright The k3sm Authors.
# SPDX-License-Identifier: Apache-2.0
#
# verify-test-count-selftest.sh -- hack/lib/test-count.sh passes a filtered
# run that ran tests and fails, with its own message, a run that ran none or
# that skipped or left out a required test. Each case is a canned runner
# output written under mktemp (removed on every exit), shaped like what
# `swift test` prints for Swift Testing and for XCTest.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

n=0
# expect <case> pass|fail <text> [helper args]: stdin is the canned output.
expect() {
	local c="$1" want="$2" text="$3" out rc=0
	shift 3
	cat >"$tmp/$c.log"
	out="$(bash "$here/lib/test-count.sh" "$tmp/$c.log" "$@" 2>&1)" || rc=$?
	if [ "$want" = pass ]; then
		[ "$rc" -eq 0 ] || { echo "FAIL: $c: want pass, got exit $rc: $out"; exit 1; }
	else
		[ "$rc" -ne 0 ] || { echo "FAIL: $c: want fail, got pass: $out"; exit 1; }
	fi
	[[ "$out" == *"$text"* ]] || { echo "FAIL: $c: want '$text', got: $out"; exit 1; }
	n=$((n + 1))
}

# What `swift test --filter NoSuchSuite` prints; it exits 0.
expect no-match fail "FAIL: the filtered test run matched no test" <<'EOF'
Building for debugging...
Build complete! (16.20 sec)
warning: No matching test cases were run
EOF

expect empty fail "FAIL: the filtered test run executed no test" </dev/null

expect zero-swift-testing fail "FAIL: the filtered test run executed no test" <<'EOF'
◇ Test run started.
✔ Test run with 0 tests passed after 0.001 seconds.
EOF

expect zero-both fail "FAIL: the filtered test run executed no test" <<'EOF'
Test Suite 'All tests' passed at 2026-11-12 08:00:00.000.
	 Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.001) seconds
◇ Test run started.
✔ Test run with 0 tests passed after 0.001 seconds.
EOF

expect swift-testing-n pass "ok: 36 tests ran" <<'EOF'
◇ Test run started.
✔ Test statusTypesCoverGoldenNodeBudgetDocuments() passed after 0.010 seconds.
✔ Suite BudgetNotifierTests passed after 31.686 seconds.
✔ Test run with 36 tests in 2 suites passed after 31.686 seconds.
EOF

expect swift-testing-one pass "ok: 1 tests ran" <<'EOF'
✔ Test run with 1 test in 1 suite passed after 0.001 seconds.
EOF

expect xctest-n pass "ok: 4 tests ran" <<'EOF'
Test Suite 'Selected tests' started at 2026-11-12 08:00:00.000.
Test Case '-[K3smSDKTests.PageTests testDecode]' passed (0.001 seconds).
Test Suite 'PageTests' passed at 2026-11-12 08:00:00.010.
	 Executed 4 tests, with 0 failures (0 unexpected) in 0.009 (0.010) seconds
Test Suite 'Selected tests' passed at 2026-11-12 08:00:00.010.
	 Executed 4 tests, with 0 failures (0 unexpected) in 0.009 (0.010) seconds
◇ Test run started.
✔ Test run with 0 tests passed after 0.001 seconds.
EOF

expect cross-process-ran pass "ok: 36 tests ran, crossProcessWakeOnNotifyEpochOnly among them" \
	--require crossProcessWakeOnNotifyEpochOnly <<'EOF'
◇ Test crossProcessWakeOnNotifyEpochOnly() started.
✔ Test crossProcessWakeOnNotifyEpochOnly() passed after 4.106 seconds.
✔ Test run with 36 tests in 2 suites passed after 31.686 seconds.
EOF

# The integration test with K3SM_SDK_INTEGRATION unset: the run passes, the test does not run.
expect cross-process-skipped fail "FAIL: crossProcessWakeOnNotifyEpochOnly was skipped" \
	--require crossProcessWakeOnNotifyEpochOnly <<'EOF'
◇ Suite BudgetNotifierTests started.
➜ Test crossProcessWakeOnNotifyEpochOnly() skipped: "integration stage only (hack/ci.sh --notifier)"
✔ Suite BudgetNotifierTests passed after 0.001 seconds.
✔ Test run with 36 tests in 2 suites passed after 0.001 seconds.
EOF

expect cross-process-absent fail "FAIL: crossProcessWakeOnNotifyEpochOnly did not run" \
	--require crossProcessWakeOnNotifyEpochOnly <<'EOF'
✔ Test seedAheadOfLiveWordReportsOnce() passed after 0.001 seconds.
✔ Test run with 35 tests in 2 suites passed after 31.686 seconds.
EOF

expect xctest-required pass "ok: 1 tests ran, testDecode among them" --require testDecode <<'EOF'
Test Case '-[K3smSDKTests.PageTests testDecode]' passed (0.001 seconds).
	 Executed 1 test, with 0 failures (0 unexpected) in 0.001 (0.001) seconds
EOF

# A test's own output that holds a summary inside a longer line is not a summary.
expect count-in-output fail "FAIL: the filtered test run executed no test" <<'EOF'
◇ Test run started.
log: fixture says "✔ Test run with 5 tests in 1 suite passed after 0.001 seconds."
note: 	 Executed 7 tests, with 0 failures (0 unexpected) in 0.001 (0.001) seconds
✔ Test run with 0 tests passed after 0.001 seconds.
EOF

# The summary line exactly as this toolchain's Swift Testing prints it.
expect swift-testing-zero-suites pass "ok: 1 tests ran" <<'EOF'
✔ Test run with 1 test in 0 suites passed after 0.009 seconds.
EOF

expect required-failed-and-passed fail "FAIL: crossProcessWakeOnNotifyEpochOnly failed" \
	--require crossProcessWakeOnNotifyEpochOnly <<'EOF'
✘ Test crossProcessWakeOnNotifyEpochOnly() failed after 4.106 seconds with 1 issue.
✔ Test crossProcessWakeOnNotifyEpochOnly() passed after 4.001 seconds.
✘ Test run with 36 tests in 2 suites failed after 31.686 seconds with 1 issue.
EOF

expect xctest-required-failed fail "FAIL: testDecode failed" --require testDecode <<'EOF'
Test Case '-[K3smSDKTests.PageTests testDecode]' failed (0.001 seconds).
Test Case '-[K3smSDKTests.PageTests testDecode]' passed (0.001 seconds).
	 Executed 2 tests, with 1 failure (0 unexpected) in 0.002 (0.002) seconds
EOF

echo "test-count self-test: $n cases ok"
