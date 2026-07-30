#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }

info "Checking whitespace and patch integrity"
git diff --check

info "Checking shell syntax"
while IFS= read -r -d '' script; do
  bash -n "$script"
done < <(find scripts -type f -name '*.sh' -print0)

if command -v shellcheck >/dev/null 2>&1; then
  info "Running ShellCheck on maintained Sentinel scripts"
  shellcheck scripts/sentinel/*.sh
fi

info "Checking pinned dependency versions"
./scripts/check-versions.sh

info "Checking Solidity formatting"
forge fmt --check

info "Generating Go contract bindings from Solidity"
./scripts/generate-bindings.sh

info "Running Go extension tests"
(
  cd go
  go test ./...
)

info "Running deployment-tool tests"
(
  cd tools
  go test ./...
)

info "Running scaffold language unit tests"
./scripts/test-unit.sh

info "Running wire-format conformance tests"
./scripts/test-conformance.sh

ok "All repository verification checks passed."
