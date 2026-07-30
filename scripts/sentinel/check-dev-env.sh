#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

readonly MIN_GO_VERSION="1.25.1"
STRICT=false
[[ "${1:-}" == "--strict" ]] && STRICT=true

failures=0

ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
bad()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; failures=$((failures + 1)); }

version_ge() {
  [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]
}

check_command() {
  local command_name="$1"
  if command -v "$command_name" >/dev/null 2>&1; then
    ok "$command_name: $(command -v "$command_name")"
  else
    bad "$command_name is not installed"
  fi
}

check_command git
check_command jq
check_command docker
check_command forge
check_command cast
check_command go

if command -v go >/dev/null 2>&1; then
  go_version="$(go version | awk '{print $3}' | sed 's/^go//')"
  if version_ge "$go_version" "$MIN_GO_VERSION"; then
    ok "Go version $go_version"
  else
    bad "Go $MIN_GO_VERSION or newer is required; found $go_version"
  fi
fi

if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then
    ok "Docker daemon is reachable"
  else
    bad "Docker is installed but the daemon is not reachable"
  fi
fi

if [[ -f .env ]]; then
  if grep -q '^LANGUAGE=go$' .env; then
    ok ".env selects LANGUAGE=go"
  else
    bad ".env must contain LANGUAGE=go"
  fi
else
  bad ".env is missing; copy .env.example to .env"
fi

if (( failures > 0 )); then
  if $STRICT; then
    exit 1
  fi
  warn "$failures environment check(s) failed."
  exit 1
fi

ok "Development environment satisfies Sentinel bootstrap requirements."
