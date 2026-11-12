#!/usr/bin/env bash
# Copyright The k3sm Authors.
# SPDX-License-Identifier: Apache-2.0
#
# test-count.sh -- fail a `swift test --filter` run that ran no test.
#
#   hack/lib/test-count.sh <log> [--require <test>]...
#
# <log> is the run's combined output. `swift test --filter <pattern>` that
# matches nothing prints "warning: No matching test cases were run" and exits
# 0, so a renamed suite would leave a filtered stage that runs nothing and
# passes. This reads the runners' own summaries instead, matched whole-line so
# a test that prints the same words cannot supply the count: Swift Testing's
# "<symbol> Test run with N tests [in M suites] passed|failed after ..." and
# XCTest's "<tab> Executed N tests, with F failures (U unexpected) in ..."
# (the largest, the outermost suite's). It fails when their sum is zero or the
# no-match warning is present. Each --require names a test function that must
# have run and passed: a skipped one (a disabled trait) fails, so does one
# with a failed line (a retried or repeated test that also passed), and so does
# one absent from the log. The run's exit status is still the caller's to
# check; this adds the count. hack/verify-test-count-selftest.sh holds its cases.
set -euo pipefail
usage() { echo "usage: hack/lib/test-count.sh <log> [--require <test>]..." >&2; exit 2; }
[ $# -ge 1 ] || usage
log="$1"; shift
required=()
while [ $# -gt 0 ]; do
	case "$1" in
		--require)
			[ $# -ge 2 ] || usage
			[[ "$2" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { echo "test-count: bad test name '$2'" >&2; exit 2; }
			required+=("$2"); shift 2 ;;
		*) usage ;;
	esac
done
[ -r "$log" ] || { echo "FAIL: test-count: cannot read $log"; exit 1; }

if grep -q 'No matching test cases were run' "$log"; then
	echo "FAIL: the filtered test run matched no test"; exit 1
fi
# The symbol before Swift Testing's summary is one glyph (a check or cross
# mark), read here as bytes: any run of up to 16 non-blank bytes, which also
# admits a colour escape around it.
swift_testing="$(LC_ALL=C sed -En 's/^[^[:space:]]{1,16} Test run with ([0-9]+) tests?( in [0-9]+ suites?)? (passed|failed) after .*/\1/p' "$log" | sort -n | tail -n 1)"
xctest="$(LC_ALL=C sed -En 's/^[[:space:]]*Executed ([0-9]+) tests?, with [0-9]+ failures? \([0-9]+ unexpected\) in .*/\1/p' "$log" | sort -n | tail -n 1)"
total=$(( ${swift_testing:-0} + ${xctest:-0} ))
if [ "$total" -eq 0 ]; then
	echo "FAIL: the filtered test run executed no test"; exit 1
fi

for t in ${required[@]+"${required[@]}"}; do
	if grep -Eq "Test ${t}\(.*\) skipped" "$log"; then
		echo "FAIL: $t was skipped"; exit 1
	fi
	if grep -Eq "Test ${t}\(.*\) failed|Test Case '.*[ .]${t}\]?' failed" "$log"; then
		echo "FAIL: $t failed"; exit 1
	fi
	grep -Eq "Test ${t}\(.*\) passed|Test Case '.*[ .]${t}\]?' passed" "$log" \
		|| { echo "FAIL: $t did not run"; exit 1; }
done
echo "    ok: $total tests ran${required[0]+, ${required[*]} among them}"
