#!/usr/bin/env bash
# Copyright The k3sm Authors.
# SPDX-License-Identifier: Apache-2.0
#
# verify-non-root-selftest.sh -- check that require_non_root in
# hack/lib/nonroot.sh can fail. Each case calls the helper in a fresh shell
# with a uid argument and asserts the return code and the output:
#   - uid 0 fails with the FAIL text, which names the reason;
#   - uid 501 passes silently;
#   - an empty-looking or non-numeric uid fails.
# It also checks statically that hack/ci.sh calls require_non_root, with no
# argument, unguarded and at top level, before its first build step (the first
# line that runs a driver in build_steps). The static check is itself tested on
# fixture scripts: a script without the call, with the call after a build step,
# passing a uid, ignoring the call's failure, hiding it in a function or block,
# or with no build step at all must each be found.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=hack/lib/nonroot.sh
. hack/lib/nonroot.sh

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# shellcheck disable=SC2016 # $1 expands in the child shell
call='. hack/lib/nonroot.sh; require_non_root "$1"'

# expect <uid> <want-rc> <want-text: empty for silent>
expect() {
	local out rc=0
	out="$(bash -c "$call" _ "$1" 2>&1)" || rc=$?
	[ "$rc" = "$2" ] || { echo "FAIL: uid '$1': exit $rc, want $2: $out"; exit 1; }
	if [ -z "$3" ]; then
		[ -z "$out" ] || { echo "FAIL: uid '$1': want no output, got: $out"; exit 1; }
		return 0
	fi
	case "$out" in
	"$3"*) ;;
	*) echo "FAIL: uid '$1': output does not start with '$3': $out"; exit 1 ;;
	esac
}

expect 0 1 "FAIL: refusing to run as root"
out="$(bash -c "$call" _ 0 2>&1)" || true
for want in "permission-denied cases" "skip as root" "Run as a non-root user"; do
	case "$out" in
	*"$want"*) ;;
	*) echo "FAIL: the root refusal does not say '$want': $out"; exit 1 ;;
	esac
done
expect 501 0 ""
expect 00 1 "FAIL: refusing to run as root"
expect abc 1 "FAIL: cannot read the effective uid"
expect -1 1 "FAIL: cannot read the effective uid"
# With no argument the helper reads id -u, so it agrees with id -u.
rc=0; bash -c '. hack/lib/nonroot.sh; require_non_root' > /dev/null 2>&1 || rc=$?
if [ "$(id -u)" = 0 ]; then want=1; else want=0; fi
[ "$rc" = "$want" ] || { echo "FAIL: require_non_root with no argument exited $rc as uid $(id -u), want $want"; exit 1; }

# build_steps: every build driver hack/ci.sh uses (swift build, swift test,
# swift package), plus the other compilers a later edit could add. One ERE
# alternation; a line matches when a driver stands as its own words.
build_steps='swift[[:space:]]+(build|test|package|run)|swiftc|xcodebuild'

# gate_check <file>: 0 when <file> calls require_non_root with no argument,
# unguarded and at top level, before its first build step; otherwise prints why
# and returns 1. The accepted call is a line that is exactly `require_non_root`
# or `require_non_root || exit <1-255>`, outside any quote, here-document,
# function body, brace group, subshell, if, case or loop. A build step is a
# non-comment line where a build_steps driver stands as its own words. The
# block depth comes from shell keywords and braces in command position, with
# quoted text, comments and here-documents skipped; a script whose structure
# does not balance, or that has no build step, fails closed.
gate_check() {
	# shellcheck disable=SC2016 # awk program, not shell
	awk -v f="$1" -v steps="$build_steps" '
		# skip: the index of the bracket closing the one at s[j], or the
		# line end when it does not close on this line.
		function skip(s, j,   o, cl, d, n, c) {
			o = substr(s, j, 1); cl = (o == "{") ? "}" : ")"; d = 0; n = length(s)
			for (; j <= n; j++) {
				c = substr(s, j, 1)
				if (c == "\\") { j++; continue }
				if (c == o) d++
				else if (c == cl && --d == 0) return j
			}
			return n
		}
		# scan: the line with quoted text replaced by Q, ${...} and $(...)
		# replaced by P and any comment dropped; sq and dq carry an open
		# quote to the next line, and hd names a here-document that starts
		# on the next line.
		function scan(s,   i, n, c, out) {
			out = ""; n = length(s)
			for (i = 1; i <= n; i++) {
				c = substr(s, i, 1)
				if (sq) { if (c == "\047") { sq = 0; out = out "Q" }; continue }
				if (dq) {
					if (c == "\\") { i++; continue }
					if (c == "\"") { dq = 0; out = out "Q" }
					continue
				}
				if (c == "\\") { i++; out = out "x"; continue }
				if (c == "$" && substr(s, i + 1, 1) ~ /[{(]/) { i = skip(s, i + 1); out = out "P"; continue }
				if (c == "\047") { sq = 1; continue }
				if (c == "\"") { dq = 1; continue }
				if (c == "<" && substr(s, i, 3) ~ /^<<[^<]/ && match(substr(s, i), /^<<-?[[:space:]]*["\047]?[A-Za-z_][A-Za-z0-9_]*/)) {
					m = substr(s, i, RLENGTH); i += RLENGTH - 1; out = out "H"
					if (m ~ /["\047]/ && substr(s, i + 1, 1) ~ /["\047]/) i++
					hdtab = (m ~ /^<<-/)
					sub(/^<<-?[[:space:]]*["\047]?/, "", m)
					hd = m
					continue
				}
				if (c == "#" && (i == 1 || substr(s, i - 1, 1) ~ /[[:space:];&|()]/)) break
				out = out c
			}
			return out
		}
		BEGIN {
			callre = "^[[:space:]]*require_non_root[[:space:]]*([|][|][[:space:]]*exit[[:space:]]+([1-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5])[[:space:]]*)?$"
			stepre = "(^|[^A-Za-z0-9_.-])(" steps ")([^A-Za-z0-9_.-]|$)"
		}
		{
			line = $0
			if (hd != "") {
				t = line; if (hdtab) sub(/^\t+/, "", t)
				if (t == hd) hd = ""
				next
			}
			quoted = (sq || dq)
			if (!quoted && call == 0 && depth == 0 && line ~ callre) call = NR
			code = scan(line)
			if (!quoted && build == 0 && line !~ /^[[:space:]]*#/ && line ~ stepre) build = NR
			gsub(/&&|[|][|]|;;|;&|[;&|]/, " ; ", code)
			n = split(code, w, /[[:space:]]+/)
			cmd = 1
			for (i = 1; i <= n; i++) {
				x = w[i]
				if (x == "") continue
				if (x == ";") { cmd = 1; continue }
				if (x == "{" || x == "(") { depth++; cmd = 1; continue }
				if (x == "}") { depth--; cmd = 0; continue }
				if (cmd) {
					if (x ~ /^(if|while|until)$/) { depth++; continue }
					if (x ~ /^(case|for|select)$/) { depth++; cmd = 0; continue }
					if (x ~ /^(fi|esac|done)$/ || x ~ /^\)/) { depth--; cmd = 0; continue }
					if (x ~ /^(then|do|else|elif|!)$/) continue
					if (x ~ /\)$/) continue # a case pattern; a command follows
				}
				cmd = 0
			}
			if (depth < 0 && bad == 0) bad = NR
		}
		END {
			if (bad != 0) { print f ": block structure does not balance at line " bad; exit 1 }
			if (depth != 0 || sq || dq || hd != "") { print f ": unterminated block, quote or here-document at end of file"; exit 1 }
			if (call == 0) { print f ": no unguarded top-level require_non_root call (with no argument)"; exit 1 }
			if (build == 0) { print f ": no recognised build step"; exit 1 }
			if (build < call) { print f ": first build step at line " build " comes before require_non_root at line " call; exit 1 }
		}' "$1"
}

fixture() {
	local name="$1"; shift
	{ echo '#!/usr/bin/env bash'; echo '# swift build in a comment is not a build step'; printf '%s\n' "$@"; } > "$tmp/$name.sh"
	echo "$tmp/$name.sh"
}
for bad in \
	"$(fixture missing 'swift build')" \
	"$(fixture after 'swift build' 'require_non_root || exit 1')" \
	"$(fixture after-test 'swift test --filter X' 'require_non_root || exit 1')" \
	"$(fixture with-uid 'require_non_root 501 || exit 1' 'swift build')" \
	"$(fixture commented '# require_non_root || exit 1' 'swift build')" \
	"$(fixture or-true 'require_non_root || true' 'swift build')" \
	"$(fixture or-colon 'require_non_root || :' 'swift build')" \
	"$(fixture then-exit0 'require_non_root; exit 0' 'swift build')" \
	"$(fixture or-exit0 'require_non_root || exit 0' 'swift build')" \
	"$(fixture or-exit256 'require_non_root || exit 256' 'swift build')" \
	"$(fixture trailing 'require_non_root || exit 1; true' 'swift build')" \
	"$(fixture in-function 'check() {' '	require_non_root || exit 1' '}' 'swift build')" \
	"$(fixture in-if-false 'if false; then' '	require_non_root || exit 1' 'fi' 'swift build')" \
	"$(fixture in-group '{' '	require_non_root' '} || true' 'swift build')" \
	"$(fixture in-heredoc 'cat <<EOF' 'require_non_root' 'EOF' 'swift build')" \
	"$(fixture after-package 'swift package resolve' 'require_non_root || exit 1' 'swift build')" \
	"$(fixture no-build 'require_non_root || exit 1' 'for tool in swift git; do :; done')"; do
	if gate_check "$bad" > /dev/null; then
		echo "FAIL: the gate check passed a bad script: $(cat "$bad")"; exit 1
	fi
done
good="$(fixture good 'require_non_root || exit 1' 'for tool in swift git; do :; done' 'swift build')"
gate_check "$good" > /dev/null || { echo "FAIL: the gate check rejected a good script: $(cat "$good")"; exit 1; }

# Static check on the real entry point.
gate_check hack/ci.sh || { echo "FAIL: hack/ci.sh does not call require_non_root before its first build step"; exit 1; }

echo "    self-test: uid 0 fails naming the skipped permission-denied cases; uid 501 passes silently; hack/ci.sh checks before any build step"
