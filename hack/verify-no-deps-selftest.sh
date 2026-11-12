#!/usr/bin/env bash
# Copyright The k3sm Authors.
# SPDX-License-Identifier: Apache-2.0
#
# verify-no-deps-selftest.sh -- hack/lib/no-deps.sh passes the clean
# `swift package show-dependencies` answer and fails, with its own message, a
# dependency tree, an empty output and an answer glued behind SwiftPM's lock
# notice (standard error mixed into the file). Each case is a canned standard
# output written under mktemp (removed on every exit).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

n=0
# expect <case> pass|fail <text>: stdin is the canned standard output.
expect() {
	local c="$1" want="$2" text="$3" out rc=0
	cat >"$tmp/$c.out"
	out="$(bash "$here/lib/no-deps.sh" "$tmp/$c.out" 2>&1)" || rc=$?
	if [ "$want" = pass ]; then
		[ "$rc" -eq 0 ] || { echo "FAIL: $c: want pass, got exit $rc: $out"; exit 1; }
	else
		[ "$rc" -ne 0 ] || { echo "FAIL: $c: want fail, got pass: $out"; exit 1; }
	fi
	[[ "$out" == *"$text"* ]] || { echo "FAIL: $c: want '$text', got: $out"; exit 1; }
	n=$((n + 1))
}

expect clean pass "ok" <<'EOF'
No external dependencies found
EOF

# The text tree SwiftPM prints for a package with dependencies.
expect listed-dependency fail "FAIL: the package must not declare dependencies" <<'EOF'
.
├── swift-argument-parser<https://github.com/apple/swift-argument-parser.git@1.5.0>
└── swift-collections<https://github.com/apple/swift-collections.git@1.1.4>
    └── swift-atomics<https://github.com/apple/swift-atomics.git@1.2.0>
EOF

expect empty fail "FAIL: show-dependencies did not report no external dependencies" </dev/null

# SwiftPM's lock notice ends without a newline; this shape means standard
# error reached the file, so the answer is not trusted.
printf '%s' "Another instance of SwiftPM (PID: 4242) is already running using '/tmp/k3sm-sdk-swift/.build', waiting until that process has finished execution..." >"$tmp/notice"
printf '%s\n' "No external dependencies found" >>"$tmp/notice"
expect glued-lock-notice fail "FAIL: show-dependencies did not report no external dependencies" <"$tmp/notice"

echo "no-deps self-test: $n cases ok"
