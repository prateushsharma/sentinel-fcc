#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

readonly EXPECTED_ORIGIN_SLUG="prateushsharma/sentinel-fcc"
readonly BASE_BRANCH="feat/protocol-v1-foundation"
readonly FEATURE_BRANCH="feat/onchain-policy-executor"
readonly ARCHIVE_RELATIVE_PATH="scripts/patches/005c-restore-expect-revert-overloads.sh"

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
    | "contracts/SentinelECDSADecisionVerifier.sol" \
    | "contracts/SentinelExecutor.sol" \
    | "contracts/SentinelPolicyRegistry.sol" \
    | "contracts/interfaces/ISentinelDecisionVerifier.sol" \
    | "contracts/interfaces/ISentinelPolicyRegistry.sol" \
    | "contracts/libraries/SentinelProtocol.sol" \
    | "docs/onchain-enforcement.md" \
    | "scripts/patches/005-onchain-policy-executor.sh" \
    | "scripts/patches/005b-fix-custom-error-tests.sh" \
    | "scripts/patches/005c-restore-expect-revert-overloads.sh" \
    | "test/SentinelECDSADecisionVerifier.t.sol" \
    | "test/SentinelExecutor.t.sol" \
    | "test/SentinelPolicyRegistry.t.sol" \
    | "sentinel_patch_005c_restore_expect_revert_overloads.sh")
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
    contracts/SentinelPolicyRegistry.sol \
    contracts/SentinelExecutor.sol \
    contracts/SentinelECDSADecisionVerifier.sol \
    test/SentinelPolicyRegistry.t.sol \
    test/SentinelExecutor.t.sol \
    test/SentinelECDSADecisionVerifier.t.sol \
    scripts/patches/005-onchain-policy-executor.sh \
    scripts/patches/005b-fix-custom-error-tests.sh; do
    [[ -f "$PROJECT_ROOT/$required" ]] ||
      die "Expected interrupted Patch 005 file missing: $required"
  done

  ok "Detected the expected interrupted Patch 005 state."
}

archive_this_patch() {
  mkdir -p "$PROJECT_ROOT/scripts/patches"
  cp "$SCRIPT_PATH" "$PROJECT_ROOT/$ARCHIVE_RELATIVE_PATH"
  chmod 0755 "$PROJECT_ROOT/$ARCHIVE_RELATIVE_PATH"
  bash -n "$PROJECT_ROOT/$ARCHIVE_RELATIVE_PATH"
  ok "Archived Patch 005c."
}

restore_expect_revert_overloads() {
  cd "$PROJECT_ROOT"

  python3 <<'PY'
from pathlib import Path

targets = [
    Path("test/SentinelPolicyRegistry.t.sol"),
    Path("test/SentinelExecutor.t.sol"),
]

bytes_signature = "    function expectRevert(bytes calldata revertData) external;\n"
bytes4_signature = "    function expectRevert(bytes4 revertData) external;\n"

for path in targets:
    text = path.read_text(encoding="utf-8")

    if bytes_signature not in text:
        raise SystemExit(f"{path}: bytes expectRevert overload was not found")

    if bytes4_signature not in text:
        text = text.replace(
            bytes_signature,
            bytes4_signature + bytes_signature,
            1,
        )

    path.write_text(text, encoding="utf-8")
PY

  ok "Restored both Foundry expectRevert overloads in test VM interfaces."
}

remove_root_script_copy() {
  if [[ "$(dirname -- "$SCRIPT_PATH")" == "$PROJECT_ROOT" && "$SCRIPT_PATH" != "$PROJECT_ROOT/$ARCHIVE_RELATIVE_PATH" ]]; then
    rm -f "$SCRIPT_PATH"
    ok "Removed duplicate root copy of Patch 005c."
  fi
}

run_full_verification() {
  cd "$PROJECT_ROOT"
  export PATH="/usr/local/go/bin:$HOME/.foundry/bin:$PATH"
  hash -r

  info "Formatting Solidity and Go sources"
  forge fmt
  gofmt -w go/pkg/protocol go/internal/protocolvectors go/cmd/protocol-vectors

  info "Checking patch integrity"
  bash -n "$ARCHIVE_RELATIVE_PATH"
  shellcheck scripts/sentinel/*.sh
  git diff --check

  info "Running all Solidity tests"
  forge test

  info "Running the complete Sentinel verification suite"
  ./scripts/sentinel/verify.sh

  ok "All Solidity, protocol, Go, scaffold, and conformance checks passed."
}

verify_change_set() {
  cd "$PROJECT_ROOT"

  python3 <<'PY'
import subprocess

allowed = {
    "README.md",
    "contracts/SentinelECDSADecisionVerifier.sol",
    "contracts/SentinelExecutor.sol",
    "contracts/SentinelPolicyRegistry.sol",
    "contracts/interfaces/ISentinelDecisionVerifier.sol",
    "contracts/interfaces/ISentinelPolicyRegistry.sol",
    "contracts/libraries/SentinelProtocol.sol",
    "docs/onchain-enforcement.md",
    "scripts/patches/005-onchain-policy-executor.sh",
    "scripts/patches/005b-fix-custom-error-tests.sh",
    "scripts/patches/005c-restore-expect-revert-overloads.sh",
    "test/SentinelECDSADecisionVerifier.t.sol",
    "test/SentinelExecutor.t.sol",
    "test/SentinelPolicyRegistry.t.sol",
}

status = subprocess.check_output(
    ["git", "status", "--porcelain=v1", "--untracked-files=all"],
    text=True,
).splitlines()

unexpected = [line for line in status if line[3:] not in allowed]
if unexpected:
    raise SystemExit(
        "Unexpected files in final Patch 005 change set:\n  "
        + "\n  ".join(unexpected)
    )
PY

  ok "Patch 005 change set contains only intended files."
}

commit_atomic_history() {
  cd "$PROJECT_ROOT"

  git add \
    contracts/SentinelPolicyRegistry.sol \
    contracts/interfaces/ISentinelPolicyRegistry.sol \
    contracts/libraries/SentinelProtocol.sol
  git diff --cached --check
  git commit -m "feat(contracts): add versioned policy commitment registry"

  git add \
    contracts/SentinelExecutor.sol \
    contracts/SentinelECDSADecisionVerifier.sol \
    contracts/interfaces/ISentinelDecisionVerifier.sol
  git diff --cached --check
  git commit -m "feat(contracts): add replay-safe decision executor"

  git add \
    test/SentinelPolicyRegistry.t.sol \
    test/SentinelExecutor.t.sol \
    test/SentinelECDSADecisionVerifier.t.sol
  git diff --cached --check
  git commit -m "test(contracts): cover policy and execution security invariants"

  git add README.md docs/onchain-enforcement.md
  git diff --cached --check
  git commit -m "docs(contracts): document onchain enforcement boundary"

  git add \
    scripts/patches/005-onchain-policy-executor.sh \
    scripts/patches/005b-fix-custom-error-tests.sh \
    "$ARCHIVE_RELATIVE_PATH"
  git diff --cached --check
  git commit -m "chore(project): archive onchain enforcement patches"

  [[ -z "$(git status --porcelain=v1)" ]] ||
    die "Working tree is not clean after Patch 005 commits."

  ok "Created five atomic Patch 005 commits."
}

push_feature_branch() {
  cd "$PROJECT_ROOT"
  git push -u origin "$FEATURE_BRANCH"

  printf '\n'
  ok "Patch 005 completed and pushed successfully."
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
  require_command forge
  require_command go
  require_command gofmt
  require_command python3
  require_command shellcheck

  validate_repository_state
  archive_this_patch
  restore_expect_revert_overloads
  remove_root_script_copy
  run_full_verification
  verify_change_set
  commit_atomic_history
  push_feature_branch
}

main "$@"
