#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT="$(git rev-parse --show-toplevel)"
VECTOR="$ROOT/testdata/protocol/v1.json"
TEMP_VECTOR="$(mktemp)"

cleanup() {
  rm -f "$TEMP_VECTOR"
}
trap cleanup EXIT

(
  cd "$ROOT/go"
  go run ./cmd/protocol-vectors > "$TEMP_VECTOR"
)

diff -u "$VECTOR" "$TEMP_VECTOR"

printf '[protocol-vectors] committed JSON matches the canonical Go generator\n'
printf '[protocol-vectors] Solidity parity is enforced by forge test\n'
