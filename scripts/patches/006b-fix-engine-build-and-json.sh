#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

readonly EXPECTED_ORIGIN_SLUG="prateushsharma/sentinel-fcc"
readonly BASE_BRANCH="feat/onchain-policy-executor"
readonly FEATURE_BRANCH="feat/confidential-policy-engine"
readonly ARCHIVE_RELATIVE_PATH="scripts/patches/006b-fix-engine-build-and-json.sh"

SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/$(basename -- "${BASH_SOURCE[0]}")"
PROJECT_ROOT="${1:-$(pwd)}"
PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd)"

info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

trap 'die "Patch failed at line $LINENO while running: $BASH_COMMAND"' ERR

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

normalize_github_slug() {
  local url="$1"
  url="${url%.git}"
  url="${url#git@github.com:}"
  url="${url#ssh://git@github.com/}"
  url="${url#https://github.com/}"
  url="${url#http://github.com/}"
  printf '%s' "$url"
}

is_expected_path() {
  case "$1" in
    "README.md" \
    | "contracts/InstructionSender.sol" \
    | "docs/confidential-policy-engine.md" \
    | "go/internal/config/config.go" \
    | "go/internal/extension/decryptor.go" \
    | "go/internal/extension/decryptor_test.go" \
    | "go/internal/extension/extension.go" \
    | "go/internal/extension/sentinel.go" \
    | "go/internal/extension/sentinel_test.go" \
    | "go/internal/policyengine/erc20.go" \
    | "go/internal/policyengine/engine.go" \
    | "go/internal/policyengine/engine_test.go" \
    | "go/internal/policyengine/types.go" \
    | "go/pkg/policy/doc.go" \
    | "go/pkg/policy/hash.go" \
    | "go/pkg/policy/normalize.go" \
    | "go/pkg/policy/policy_test.go" \
    | "go/pkg/policy/types.go" \
    | "go/pkg/policy/uint256.go" \
    | "go/pkg/types/sentinel.go" \
    | "scripts/patches/006-confidential-policy-engine.sh" \
    | "scripts/patches/006b-fix-engine-build-and-json.sh" \
    | "sentinel_patch_006b_fix_engine_build_and_json.sh")
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

validate_repository_state() {
  local branch origin_url origin_slug status_line path

  [[ -d "$PROJECT_ROOT/.git" ]] || die "Not a Git repository: $PROJECT_ROOT"

  branch="$(git -C "$PROJECT_ROOT" branch --show-current)"
  [[ "$branch" == "$FEATURE_BRANCH" ]] ||
    die "Run this patch on '$FEATURE_BRANCH'; current branch is '$branch'."

  origin_url="$(git -C "$PROJECT_ROOT" remote get-url origin 2>/dev/null || true)"
  origin_slug="$(normalize_github_slug "$origin_url")"
  [[ "$origin_slug" == "$EXPECTED_ORIGIN_SLUG" ]] ||
    die "Unexpected origin remote: $origin_url"

  git -C "$PROJECT_ROOT" fetch origin "$BASE_BRANCH" --prune

  [[ "$(git -C "$PROJECT_ROOT" merge-base HEAD "origin/$BASE_BRANCH")" == "$(git -C "$PROJECT_ROOT" rev-parse "origin/$BASE_BRANCH")" ]] ||
    die "Feature branch is not based on current origin/$BASE_BRANCH."

  [[ "$(git -C "$PROJECT_ROOT" rev-list --count "origin/$BASE_BRANCH..HEAD")" == "0" ]] ||
    die "Feature branch already contains commits."

  git -C "$PROJECT_ROOT" diff --cached --quiet ||
    die "The Git index already contains staged changes."

  while IFS= read -r status_line; do
    [[ -z "$status_line" ]] && continue
    path="${status_line:3}"
    [[ "$path" == *" -> "* ]] && path="${path##* -> }"

    if ! is_expected_path "$path"; then
      printf '%s\n' "$status_line" >&2
      die "Unexpected working-tree change detected: $path"
    fi
  done < <(git -C "$PROJECT_ROOT" status --porcelain=v1 --untracked-files=all)

  for required in \
    go/pkg/policy/types.go \
    go/pkg/policy/hash.go \
    go/internal/policyengine/engine.go \
    go/internal/extension/sentinel.go \
    go/pkg/types/sentinel.go \
    contracts/InstructionSender.sol \
    scripts/patches/006-confidential-policy-engine.sh; do
    [[ -f "$PROJECT_ROOT/$required" ]] ||
      die "Expected interrupted Patch 006 file missing: $required"
  done

  ok "Detected the expected interrupted Patch 006 state."
}

archive_this_patch() {
  mkdir -p "$PROJECT_ROOT/scripts/patches"
  cp "$SCRIPT_PATH" "$PROJECT_ROOT/$ARCHIVE_RELATIVE_PATH"
  chmod 0755 "$PROJECT_ROOT/$ARCHIVE_RELATIVE_PATH"
  bash -n "$PROJECT_ROOT/$ARCHIVE_RELATIVE_PATH"
  ok "Archived Patch 006b."
}

fix_engine_and_json_decoder() {
  cd "$PROJECT_ROOT"

  python3 <<'PY'
from pathlib import Path

engine_path = Path("go/internal/policyengine/engine.go")
engine = engine_path.read_text(encoding="utf-8")

old_comparison = "if a.score > protocol.MaximumRiskScore {"
new_comparison = "if a.score > uint16(protocol.MaximumRiskScore) {"

if old_comparison in engine:
    engine = engine.replace(old_comparison, new_comparison, 1)
elif new_comparison not in engine:
    raise SystemExit("risk-score comparison anchor was not found")

engine_path.write_text(engine, encoding="utf-8")

sentinel_path = Path("go/internal/extension/sentinel.go")
sentinel = sentinel_path.read_text(encoding="utf-8")

import_anchor = '\t"fmt"\n\t"net/http"\n'
import_replacement = '\t"fmt"\n\t"io"\n\t"net/http"\n'
if '\t"io"\n' not in sentinel:
    if import_anchor not in sentinel:
        raise SystemExit("sentinel.go import anchor was not found")
    sentinel = sentinel.replace(import_anchor, import_replacement, 1)

old_trailing_check = """\tif decoder.More() {
\t\treturn buildResult(
\t\t\taction,
\t\t\tdataFixed,
\t\t\tnil,
\t\t\t0,
\t\t\tfmt.Errorf("decoding evaluation request: trailing JSON values"),
\t\t)
\t}
"""

new_trailing_check = """\tvar trailing any
\tif err := decoder.Decode(&trailing); err != io.EOF {
\t\tif err == nil {
\t\t\terr = fmt.Errorf("multiple top-level JSON values")
\t\t}
\t\treturn buildResult(
\t\t\taction,
\t\t\tdataFixed,
\t\t\tnil,
\t\t\t0,
\t\t\tfmt.Errorf("decoding evaluation request: trailing data: %w", err),
\t\t)
\t}
"""

if old_trailing_check in sentinel:
    sentinel = sentinel.replace(old_trailing_check, new_trailing_check, 1)
elif new_trailing_check not in sentinel:
    raise SystemExit("sentinel.go trailing JSON check anchor was not found")

sentinel_path.write_text(sentinel, encoding="utf-8")
PY

  ok "Fixed risk-score type conversion and strict top-level JSON termination."
}

remove_root_script_copy() {
  if [[ "$(dirname -- "$SCRIPT_PATH")" == "$PROJECT_ROOT" && "$SCRIPT_PATH" != "$PROJECT_ROOT/$ARCHIVE_RELATIVE_PATH" ]]; then
    rm -f "$SCRIPT_PATH"
    ok "Removed duplicate root copy of Patch 006b."
  fi
}

run_full_verification() {
  cd "$PROJECT_ROOT"
  export PATH="/usr/local/go/bin:$HOME/.foundry/bin:$PATH"
  hash -r

  info "Formatting Go and Solidity sources"
  gofmt -w \
    go/pkg/policy \
    go/internal/policyengine \
    go/pkg/types/sentinel.go \
    go/internal/extension/decryptor.go \
    go/internal/extension/sentinel.go \
    go/internal/extension/decryptor_test.go \
    go/internal/extension/sentinel_test.go \
    go/internal/config/config.go \
    go/internal/extension/extension.go
  forge fmt

  info "Checking scripts and whitespace"
  bash -n "$ARCHIVE_RELATIVE_PATH"
  shellcheck scripts/sentinel/*.sh
  git diff --check

  info "Running focused policy and extension tests"
  (
    cd go
    go test ./pkg/policy ./internal/policyengine ./internal/extension ./pkg/types
  )

  info "Running the complete Sentinel verification suite"
  ./scripts/sentinel/verify.sh

  ok "All policy, extension, Solidity, Go, scaffold, and conformance checks passed."
}

verify_change_set() {
  cd "$PROJECT_ROOT"

  python3 <<'PY'
import subprocess

allowed = {
    "README.md",
    "contracts/InstructionSender.sol",
    "docs/confidential-policy-engine.md",
    "go/internal/config/config.go",
    "go/internal/extension/decryptor.go",
    "go/internal/extension/decryptor_test.go",
    "go/internal/extension/extension.go",
    "go/internal/extension/sentinel.go",
    "go/internal/extension/sentinel_test.go",
    "go/internal/policyengine/erc20.go",
    "go/internal/policyengine/engine.go",
    "go/internal/policyengine/engine_test.go",
    "go/internal/policyengine/types.go",
    "go/pkg/policy/doc.go",
    "go/pkg/policy/hash.go",
    "go/pkg/policy/normalize.go",
    "go/pkg/policy/policy_test.go",
    "go/pkg/policy/types.go",
    "go/pkg/policy/uint256.go",
    "go/pkg/types/sentinel.go",
    "scripts/patches/006-confidential-policy-engine.sh",
    "scripts/patches/006b-fix-engine-build-and-json.sh",
}

status = subprocess.check_output(
    ["git", "status", "--porcelain=v1", "--untracked-files=all"],
    text=True,
).splitlines()

unexpected = [line for line in status if line[3:] not in allowed]
if unexpected:
    raise SystemExit(
        "Unexpected files in final Patch 006 change set:\n  "
        + "\n  ".join(unexpected)
    )
PY

  ok "Patch 006 change set contains only intended files."
}

commit_atomic_history() {
  cd "$PROJECT_ROOT"

  git add go/pkg/policy
  git diff --cached --check
  git commit -m "feat(policy): add canonical confidential policy schema"

  git add go/internal/policyengine
  git diff --cached --check
  git commit -m "feat(engine): add deterministic transaction policy evaluator"

  git add \
    go/pkg/types/sentinel.go \
    go/internal/config/config.go \
    go/internal/extension/extension.go \
    go/internal/extension/decryptor.go \
    go/internal/extension/sentinel.go \
    contracts/InstructionSender.sol
  git diff --cached --check
  git commit -m "feat(extension): add encrypted sentinel evaluation route"

  git add \
    go/internal/extension/decryptor_test.go \
    go/internal/extension/sentinel_test.go
  git diff --cached --check
  git commit -m "test(engine): cover confidential evaluation boundary"

  git add README.md docs/confidential-policy-engine.md
  git diff --cached --check
  git commit -m "docs(engine): document private policy evaluation"

  git add \
    scripts/patches/006-confidential-policy-engine.sh \
    "$ARCHIVE_RELATIVE_PATH"
  git diff --cached --check
  git commit -m "chore(project): archive confidential policy patches"

  [[ -z "$(git status --porcelain=v1)" ]] ||
    die "Working tree is not clean after Patch 006 commits."

  ok "Created six atomic Patch 006 commits."
}

push_feature_branch() {
  cd "$PROJECT_ROOT"
  git push -u origin "$FEATURE_BRANCH"

  printf '\n'
  ok "Patch 006 completed and pushed successfully."
  printf 'Branch: %s\n' "$FEATURE_BRANCH"
  printf 'Head:   %s\n' "$(git rev-parse --short HEAD)"
  printf 'Base:   %s\n' "$BASE_BRANCH"
  printf '\nCommits:\n'
  git log --oneline "origin/$BASE_BRANCH..HEAD"
  printf '\nPull request:\n'
  printf 'https://github.com/prateushsharma/sentinel-fcc/compare/%s...%s?expand=1\n' \
    "$BASE_BRANCH" "$FEATURE_BRANCH"
}

main() {
  require_command git
  require_command go
  require_command gofmt
  require_command forge
  require_command python3
  require_command shellcheck

  validate_repository_state
  archive_this_patch
  fix_engine_and_json_decoder
  remove_root_script_copy
  run_full_verification
  verify_change_set
  commit_atomic_history
  push_feature_branch
}

main "$@"
