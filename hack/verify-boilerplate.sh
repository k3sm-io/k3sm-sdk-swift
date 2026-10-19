#!/usr/bin/env bash
# Copyright The k3sm Authors.
# SPDX-License-Identifier: Apache-2.0
#
# verify-boilerplate.sh [--self-test] -- every .swift file starts with the
# Apache-2.0 header in hack/boilerplate/boilerplate.swift.txt, byte for byte.
# A manifest (Package.swift, Package@swift-*.swift) keeps its
# swift-tools-version comment on line 1, so its header starts on line 2.
set -euo pipefail
cd "$(dirname "$0")/.."
header="hack/boilerplate/boilerplate.swift.txt"

# check <root>: print each file under <root> missing the header; exit 1 if any.
check() {
	local root="$1" n missing=0 f start
	n="$(wc -l < "$header" | tr -d ' ')"
	while IFS= read -r -d '' f; do
		start=1
		if head -n 1 "$f" | grep -q '^// swift-tools-version'; then start=2; fi
		# sed reads the whole file, so nothing dies of SIGPIPE under pipefail.
		if ! sed -n "${start},$((start + n - 1))p" "$f" | cmp -s - "$header"; then
			echo "    missing header: ${f#"$root"/}"; missing=1
		fi
	done < <(find "$root" \( -name .git -o -name .build -o -name .swiftpm -o -name out \) -prune -o \
		-type f -name '*.swift' -print0)
	return "$missing"
}

if [ "${1:-}" = --self-test ]; then
	tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
	{ cat "$header"; printf '\nlet a = 1\n'; } > "$tmp/Good.swift"
	{ echo '// swift-tools-version:6.0'; cat "$header"; printf '\nimport PackageDescription\n'; } > "$tmp/Package.swift"
	check "$tmp" > /dev/null || { echo "FAIL: a file with the header was flagged"; exit 1; }
	mkdir "$tmp/m"; printf '// swift-tools-version:6.0\nimport PackageDescription\n' > "$tmp/m/Package.swift"
	if check "$tmp/m" > /dev/null; then echo "FAIL: a manifest without the header passed"; exit 1; fi
	printf 'let b = 2\n' > "$tmp/Bad.swift"
	if check "$tmp" > /dev/null; then echo "FAIL: a file without the header passed"; exit 1; fi
	echo "    self-test: a headed file and a headed manifest pass, a bare manifest and a bare file fail"
	exit 0
fi

if ! check "$PWD"; then
	echo "FAIL: add the header in $header to the files above"; exit 1
fi
echo "    ok"
