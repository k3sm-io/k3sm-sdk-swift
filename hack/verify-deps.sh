#!/usr/bin/env bash
# Copyright The k3sm Authors.
# SPDX-License-Identifier: Apache-2.0
#
# verify-deps.sh [--self-test] [root] -- the dependency supply-chain check.
#
#   1. every .package( in Package.swift and Package@swift-*.swift is listed in
#      hack/deps.allow (format: <url> <40-hex revision sha> <reason>); comments
#      are stripped, each call is parsed alone and carries exactly one url:,
#      and no other Package.swift may exist below the root
#   2. an allowed package is pinned by .revision("<sha>") or exact:, never
#      from:, branch: or a range; a .revision must equal the allowed sha
#   3. Package.resolved exists, is committed, and carries the allowed sha
#   4. a hack/**/*.sh that downloads (curl, wget) verifies a sha256 in the
#      same script (shasum -a 256 -c, or a compared digest)
#
# With no package dependencies the allow file holds only comments and rules 2
# and 3 have nothing to check. --self-test runs the rules against the
# hermetic fixtures in hack/testdata/verify-deps/.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
fixtures="$here/testdata/verify-deps"

# package_calls <manifest>: print the argument text of each .package( call on
# its own line. Comments are stripped first (string literals are respected, so
# the // in a URL survives) and each call ends at its own matching close paren.
package_calls() {
	awk '
	{ t = t $0 "\n" }
	END {
		n = length(t); st = 0; c = ""
		for (i = 1; i <= n; i++) {
			ch = substr(t, i, 1); nx = substr(t, i + 1, 1)
			if (st == 0) {
				if (ch == "\"") { st = 1; c = c ch }
				else if (ch == "/" && nx == "/") { st = 2; i++ }
				else if (ch == "/" && nx == "*") { st = 3; i++; c = c " " }
				else c = c ch
			} else if (st == 1) {
				c = c ch
				if (ch == "\\") { c = c nx; i++ } else if (ch == "\"") st = 0
			} else if (st == 2) {
				if (ch == "\n") { st = 0; c = c ch }
			} else if (ch == "*" && nx == "/") { st = 0; i++ }
		}
		gsub(/\n/, " ", c)
		n = length(c); key = ".package("; pos = 1
		while ((k = index(substr(c, pos), key)) > 0) {
			start = pos + k - 1 + length(key); depth = 1; st = 0
			for (i = start; i <= n && depth > 0; i++) {
				ch = substr(c, i, 1)
				if (st == 1) { if (ch == "\\") i++; else if (ch == "\"") st = 0 }
				else if (ch == "\"") st = 1
				else if (ch == "(") depth++
				else if (ch == ")") depth--
			}
			print substr(c, start, i - start - 1)
			pos = i
		}
	}' "$1"
}

# check_manifest <manifest> <root> <check-committed>: rules 1 to 3 for one manifest.
check_manifest() {
	local manifest="$1" root="$2" committed="$3" bad=0
	local allow="$root/hack/deps.allow" chunk url rev sha nurl label
	label="${manifest#"$root"/}"
	while IFS= read -r chunk; do
		[ -n "$chunk" ] || continue
		nurl="$(printf '%s' "$chunk" | grep -Eo 'url:[[:space:]]*"' | wc -l | tr -d ' ')"
		if [ "$nurl" != 1 ]; then
			echo "    FAIL: $label: a .package( call must carry exactly one url: (found $nurl)"; bad=1; continue
		fi
		url="$(printf '%s' "$chunk" | sed -n 's/.*url:[[:space:]]*"\([^"]*\)".*/\1/p')"
		sha="$(awk -v u="$url" '$1 == u && $2 ~ /^[0-9a-f]{40}$/ && NF >= 3 {print $2; exit}' "$allow")"
		if [ -z "$sha" ]; then fail "$label: $url is not in hack/deps.allow (or has no 40-hex revision and reason)"; bad=1; continue; fi
		if printf '%s' "$chunk" | grep -Eq 'from:|branch:|upToNext|\.\.[.<]'; then
			fail "$url: pin by .revision(\"<sha>\") or exact:, not from:, branch: or a range"; bad=1; continue
		fi
		rev="$(printf '%s' "$chunk" | sed -nE 's/.*revision(:[[:space:]]*|\()"([0-9a-f]{40})".*/\2/p')"
		if [ -n "$rev" ]; then
			[ "$rev" = "$sha" ] || { fail "$url: .revision $rev differs from the allowed $sha"; bad=1; }
		elif ! printf '%s' "$chunk" | grep -Eq 'exact:'; then
			fail "$url: not pinned by .revision(\"<40-hex sha>\") or exact:"; bad=1
		fi
		if [ ! -f "$root/Package.resolved" ]; then
			fail "$url: Package.resolved is missing"; bad=1
		else
			if [ "$committed" = 1 ]; then
				git -C "$root" ls-files --error-unmatch Package.resolved >/dev/null 2>&1 \
					|| { fail "Package.resolved is not committed"; bad=1; }
			fi
			if ! { grep -Fq "$url" "$root/Package.resolved" && grep -Fq "$sha" "$root/Package.resolved"; }; then
				fail "$url: Package.resolved does not carry the allowed revision $sha"; bad=1
			fi
		fi
	done < <(package_calls "$manifest")
	return "$bad"
}

fail() { echo "    FAIL: $*"; }

# check <root> <check-committed 0|1>: print each violation, return 1 if any.
check() {
	local root="$1" committed="$2" bad=0 m f
	[ -f "$root/Package.swift" ] || { echo "    FAIL: no Package.swift in $root"; return 1; }
	[ -f "$root/hack/deps.allow" ] || { echo "    FAIL: no hack/deps.allow in $root"; return 1; }

	for m in "$root/Package.swift" "$root"/Package@swift-*.swift; do
		[ -f "$m" ] || continue
		check_manifest "$m" "$root" "$committed" || bad=1
	done
	# A manifest below the root is one SwiftPM may resolve as a local package.
	while IFS= read -r -d '' f; do
		echo "    FAIL: ${f#"$root"/}: a Package.swift below the root is not allowed"; bad=1
	done < <(find "$root" -name Package.swift -not -path "$root/Package.swift" \
		-not -path "$root/hack/testdata/*" -not -path '*/.build/*' -not -path '*/.git/*' -print0)

	# Downloaders need a digest check in the same script. This script and the
	# fixtures are exempt: it names the tools only to look for them.
	local dl='(^|[[:space:];&|(`])(curl|wget)[[:space:]]'
	local f
	if [ -d "$root/hack" ]; then
		while IFS= read -r -d '' f; do
			[ "$(basename "$f")" != verify-deps.sh ] || continue
			if grep -Ev '^[[:space:]]*#' "$f" | grep -Eq "$dl"; then
				{ grep -Eq 'shasum -a 256 -c|sha256sum -c' "$f" \
					|| { grep -Eq 'shasum -a 256|sha256sum|dgst -sha256' "$f" && grep -Eq '\[\[? .*[^!=]=?=[^=~]' "$f"; }; } \
					|| { fail "${f#"$root"/}: downloads without a sha256 verification"; bad=1; }
			fi
		done < <(find "$root/hack" -name '*.sh' -not -path '*/testdata/*' -print0)
	fi
	return "$bad"
}

# stage_fixture <case dir> <dest>: Package.* lands at the root, deps.allow and
# *.fixture scripts under hack/. The .fixture suffix keeps shellcheck and the
# license-header scan from treating a fixture as live source.
stage_fixture() {
	local src="$1" dest="$2" f name
	mkdir -p "$dest/hack"
	for f in "$src"/*; do
		name="$(basename "$f")"
		case "$name" in
		expect) ;;
		nested-Package.swift.fixture) mkdir -p "$dest/Sources/nested"; cp "$f" "$dest/Sources/nested/Package.swift" ;;
		Package.*|Package@*) cp "$f" "$dest/${name%.fixture}" ;;
		*) cp "$f" "$dest/hack/${name%.fixture}" ;;
		esac
	done
}

self_test() {
	local tmp d name want substr out status n=0
	tmp="$(mktemp -d)"
	trap 'rm -rf "$tmp"' RETURN
	for d in "$fixtures"/*/; do
		name="$(basename "$d")"
		read -r want substr < "$d/expect"
		substr="${substr:-}"
		stage_fixture "$d" "$tmp/$name"
		status=0
		out="$(check "$tmp/$name" 0 2>&1)" || status=$?
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
	[ "$n" -gt 0 ] || { echo "FAIL: no fixtures under $fixtures"; return 1; }
	echo "verify-deps self-test: $n cases ok"
}

case "${1:-}" in
--self-test) self_test ;;
*)
	root="${1:-$here/..}"
	root="$(cd "$root" && pwd)"
	if check "$root" 1; then echo "    ok"; else echo "FAIL: dependency supply-chain check"; exit 1; fi
	;;
esac
