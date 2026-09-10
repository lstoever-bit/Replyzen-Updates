#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="${1:-$ROOT/source-current}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc -parse-as-library \
  "$SOURCE/app/OutlookCalendarItemContext.swift" \
  "$ROOT/tests/CalendarInviteContextTests.swift" \
  -o "$TMP/calendar-invite-tests"
"$TMP/calendar-invite-tests"
