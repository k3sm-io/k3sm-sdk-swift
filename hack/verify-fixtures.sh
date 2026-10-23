#!/usr/bin/env bash
# Copyright The k3sm Authors.
# SPDX-License-Identifier: Apache-2.0
#
# verify-fixtures.sh [--self-test] [dir] -- the vendored test fixtures are the
# bytes their manifest names.
#
#   1. <dir>/FIXTURES.sha256 exists and carries at least one digest line, in
#      `shasum -a 256` format ("<64 hex>  <file name>"); '#' lines are comments
#   2. `shasum -a 256 -c` passes: every listed file exists with its digest
#   3. every other file in <dir> has a digest line, so an undigested fixture
#      cannot ride along
#
# The default dir is Tests/K3smSDKTests/Fixtures/nodebudget. --self-test runs
# the rules against the hermetic fixtures in hack/testdata/verify-fixtures/,
# each a directory of files plus an `expect` line: "pass" or "fail <text>".
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
cases="$here/testdata/verify-fixtures"
manifest_name=FIXTURES.sha256

# check <dir>: print each problem; exit 1 if any.
check() {
	local dir="$1" manifest bad=0 line f name out
	manifest="$dir/$manifest_name"
	[ -f "$manifest" ] || { echo "    FAIL: no $manifest_name in $dir"; return 1; }
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in '#'*|'') continue ;; esac
		if ! printf '%s\n' "$line" | grep -Eq '^[0-9a-f]{64}  [^/]+$'; then
			echo "    FAIL: $manifest_name: not a digest line: $line"; bad=1
		fi
	done < "$manifest"
	if ! grep -Eq '^[0-9a-f]{64}  ' "$manifest"; then
		echo "    FAIL: $manifest_name carries no digest line"; return 1
	fi
	[ "$bad" = 0 ] || return 1
	if ! out="$(cd "$dir" && shasum -a 256 -c "$manifest_name" 2>&1)"; then
		printf '%s\n' "$out" | sed 's/^/    /'
		echo "    FAIL: a fixture does not match its digest"; bad=1
	fi
	while IFS= read -r -d '' f; do
		name="$(basename "$f")"
		[ "$name" = "$manifest_name" ] && continue
		if ! awk -v n="$name" '$1 ~ /^[0-9a-f]{64}$/ && substr($0, 67) == n { found = 1 } END { exit !found }' "$manifest"; then
			echo "    FAIL: $name has no digest line in $manifest_name"; bad=1
		fi
	done < <(find "$dir" -mindepth 1 -maxdepth 1 -print0)
	return "$bad"
}

self_test() {
	local tmp d name want substr out status n=0
	tmp="$(mktemp -d)"
	trap 'rm -rf "$tmp"' RETURN
	for d in "$cases"/*/; do
		name="$(basename "$d")"
		read -r want substr < "$d/expect"
		substr="${substr:-}"
		mkdir "$tmp/$name"
		find "$d" -mindepth 1 -maxdepth 1 -type f ! -name expect -exec cp -p {} "$tmp/$name/" \;
		status=0
		out="$(check "$tmp/$name" 2>&1)" || status=$?
		case "$want" in
		pass) [ "$status" = 0 ] || { echo "FAIL: $name should pass:"; echo "$out"; return 1; } ;;
		fail)
			[ "$status" != 0 ] || { echo "FAIL: $name should be refused"; return 1; }
			printf '%s' "$out" | grep -Fq -- "$substr" || { echo "FAIL: $name: no '$substr' in:"; echo "$out"; return 1; }
			;;
		*) echo "FAIL: $name: bad expect file"; return 1 ;;
		esac
		echo "    $want: $name"
		n=$((n + 1))
	done
	[ "$n" -gt 0 ] || { echo "FAIL: no cases under $cases"; return 1; }
	echo "verify-fixtures self-test: $n cases ok"
}

case "${1:-}" in
--self-test) self_test ;;
*)
	dir="${1:-$here/../Tests/K3smSDKTests/Fixtures/nodebudget}"
	dir="$(cd "$dir" && pwd)"
	if check "$dir"; then echo "    ok"; else echo "FAIL: vendored fixtures ($dir)"; exit 1; fi
	;;
esac
