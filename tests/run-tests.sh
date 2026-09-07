#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="${1:-$ROOT/source-current}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
python3 "$ROOT/tests/test_source_contracts.py" "$SOURCE"
swiftc -parse-as-library "$SOURCE/app/ResponseJSON.swift" "$ROOT/tests/ResponseJSONTests.swift" -o "$TMP/json-tests"
"$TMP/json-tests"
cat "$ROOT/tests/ClientStubs.swift" "$SOURCE/app/OpenAIClient.swift" > "$TMP/ClientChecks.swift"
printf '\n' >> "$TMP/ClientChecks.swift"
cat "$ROOT/tests/ClientDecoderChecks.swift" >> "$TMP/ClientChecks.swift"
swiftc -parse-as-library "$SOURCE/app/ResponseJSON.swift" "$TMP/ClientChecks.swift" -o "$TMP/client-tests"
"$TMP/client-tests"
bash -n "$SOURCE/Build-CI.sh"
