#!/usr/bin/env bash
# Copyright The k3sm Authors.
# SPDX-License-Identifier: Apache-2.0
#
# no-deps.sh -- pass a `swift package show-dependencies` answer that says the
# package declares no dependencies.
#
#   hack/lib/no-deps.sh <stdout>
#
# <stdout> is the command's standard output alone; the caller keeps standard
# error apart and checks the command's exit status itself. SwiftPM writes
# notices on standard error without a trailing newline (the "Another instance
# of SwiftPM ... waiting until that process has finished execution..." lock
# notice), so in a combined capture the answer can arrive glued to the end of
# a notice and a line-anchored match no longer sees it. On standard output
# the answer is a whole line: this passes when a line starts with "No external
# dependencies found" and no line is a dependency tree entry. A notice glued
# before the answer means standard error reached the file, and it fails.
# hack/verify-no-deps-selftest.sh holds its cases.
set -euo pipefail
[ $# -eq 1 ] || { echo "usage: hack/lib/no-deps.sh <stdout>" >&2; exit 2; }
out="$1"
[ -r "$out" ] || { echo "FAIL: no-deps: cannot read $out"; exit 1; }

if grep -Eq '(├|└)── ' "$out"; then
	echo "FAIL: the package must not declare dependencies"; exit 1
fi
grep -q '^No external dependencies found' "$out" \
	|| { echo "FAIL: show-dependencies did not report no external dependencies"; exit 1; }
echo "    ok"
