#!/usr/bin/env bash
# Copyright The k3sm Authors.
# SPDX-License-Identifier: Apache-2.0
#
# verify-version-selftest.sh -- hack/verify-version.sh passes a consistent tree
# and fails, with its own message, on each mismatch it checks. Each case is a
# fake tree under mktemp (removed on every exit) holding a copy of the script,
# a Version.swift, a README.md and a CLAUDE.md; the tag cases add a throwaway
# git repository with local identity and no global or system config.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export GIT_CEILING_DIRECTORIES="$tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
sha=0123456789abcdef0123456789abcdef01234567

# mk <dir> <major> <minor> <patch> <string> [readme tag comment]
mk() {
	local d="$tmp/$1"
	mkdir -p "$d/hack" "$d/Sources/K3smSDK"
	cp "$here/verify-version.sh" "$d/hack/"
	{
		[ -z "$2" ] || printf '    public static let major = %s\n' "$2"
		[ -z "$3" ] || printf '    public static let minor = %s\n' "$3"
		[ -z "$4" ] || printf '    public static let patch = %s\n' "$4"
		[ -z "$5" ] || printf '    public static let string = "%s"\n' "$5"
		printf '    public static let pageABIMajor = 1\n'
	} >"$d/Sources/K3smSDK/Version.swift"
	printf '    .package(url: "https://example.invalid/sdk.git", revision: "%s"), // %s\n' \
		"$sha" "${6:-v1.2.3}" >"$d/README.md"
	printf 'A consumer pins .package(url:, revision: "<40-hex sha>") // vX.Y.Z.\n' >"$d/CLAUDE.md"
}

# tag <dir> <tag>: make the tree a git repo whose HEAD carries <tag>.
tag() {
	local d="$tmp/$1"
	git -C "$d" init -q
	git -C "$d" config user.name selftest
	git -C "$d" config user.email selftest@example.invalid
	git -C "$d" add -A
	git -C "$d" -c commit.gpgsign=false commit -qm fixture
	git -C "$d" -c tag.gpgsign=false tag "$2"
}

n=0
# expect <dir> pass | expect <dir> fail <text>
expect() {
	local d="$1" want="$2" text="${3:-}" out rc=0
	out="$(bash "$tmp/$d/hack/verify-version.sh" 2>&1)" || rc=$?
	if [ "$want" = pass ]; then
		[ "$rc" -eq 0 ] || { echo "FAIL: $d: want pass, got exit $rc: $out"; exit 1; }
	else
		[ "$rc" -ne 0 ] || { echo "FAIL: $d: want fail, got pass: $out"; exit 1; }
		[[ "$out" == *"$text"* ]] || { echo "FAIL: $d: want '$text', got: $out"; exit 1; }
	fi
	n=$((n + 1))
}

mk ok 1 2 3 1.2.3
expect ok pass

mk ok-tag 1 2 3 1.2.3
tag ok-tag v1.2.3
expect ok-tag pass

mk string-mismatch 1 2 3 1.2.4
expect string-mismatch fail "FAIL: string is 1.2.4, numbers say 1.2.3"

mk wrong-tag 1 2 3 1.2.3
tag wrong-tag v1.2.4
expect wrong-tag fail "FAIL: tag v1.2.4 on HEAD, K3smSDKVersion is 1.2.3"

mk malformed-comment 1 2 3 1.2.3 v1.2
expect malformed-comment fail "FAIL: README.md: malformed tag comment 'v1.2'"

mk no-constants "" "" "" ""
expect no-constants fail "FAIL: no version constants in Sources/K3smSDK/Version.swift"

echo "verify-version self-test: $n cases ok"
