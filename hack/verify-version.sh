#!/usr/bin/env bash
# Copyright The k3sm Authors.
# SPDX-License-Identifier: Apache-2.0
#
# verify-version.sh -- K3smSDKVersion's constants name one version, and a v* tag
# on HEAD, when there is one, equals it. A "// vX.Y.Z" comment after a pinned
# revision in README.md or CLAUDE.md, when present, must be a well-formed tag.
set -euo pipefail
cd "$(dirname "$0")/.."
src=Sources/K3smSDK/Version.swift
num() { sed -n "s/.*static let $1 = \([0-9]\{1,\}\)\$/\1/p" "$src"; }
ver="$(num major).$(num minor).$(num patch)"
str="$(sed -n 's/.*static let string = "\(.*\)"$/\1/p' "$src")"
[ "$ver" != ".." ] || { echo "FAIL: no version constants in $src"; exit 1; }
[ "$str" = "$ver" ] || { echo "FAIL: string is $str, numbers say $ver"; exit 1; }
for t in $(git tag --points-at HEAD 'v*' 2>/dev/null || true); do
	[ "$t" = "v$ver" ] || { echo "FAIL: tag $t on HEAD, K3smSDKVersion is $ver"; exit 1; }
done
for f in README.md CLAUDE.md; do
	while IFS= read -r t; do
		[[ "$t" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "FAIL: $f: malformed tag comment '$t'"; exit 1; }
	done < <(sed -n 's/.*revision:[[:space:]]*"[0-9a-f]\{40\}"),\{0,1\}[[:space:]]*\/\/[[:space:]]*\([^[:space:]]*\).*/\1/p' "$f")
done
echo "    ok (version $ver)"
