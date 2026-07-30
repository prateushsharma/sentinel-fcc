#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

readonly EXPECTED_ORIGIN_SLUG="prateushsharma/sentinel-fcc"
readonly REQUIRED_BRANCH="develop"
readonly ARCHIVE_RELATIVE_PATH="scripts/patches/003d-resume-and-finish.sh"
readonly COMMIT_MESSAGE="chore(dev): prepare reproducible workstation setup"

SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/$(basename -- "${BASH_SOURCE[0]}")"
SCRIPT_BASENAME="$(basename -- "$SCRIPT_PATH")"
PROJECT_ROOT="${1:-$(pwd)}"
PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd)"

info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
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

is_allowed_path() {
  case "$1" in
    ".github/workflows/quality.yml" \
    | "README.md" \
    | "docs/development-setup.md" \
    | "scripts/sentinel/verify.sh" \
    | "scripts/patches/003-prepare-workstation.sh" \
    | "scripts/patches/003b-finish-workstation.sh" \
    | "scripts/patches/003c-generate-bindings-and-finish.sh" \
    | "scripts/patches/003d-resume-and-finish.sh" \
    | "contracts/InstructionSender.sol" \
    | "contracts/interfaces/ITeeExtensionRegistry.sol" \
    | "contracts/interfaces/ITeeMachineRegistry.sol" \
    | "sentinel_patch_003_prepare_workstation.sh" \
    | "sentinel_patch_003b_finish_workstation.sh" \
    | "sentinel_patch_003c_generate_bindings_and_finish.sh" \
    | "sentinel_patch_003d_resume_and_finish.sh")
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
  [[ "$branch" == "$REQUIRED_BRANCH" ]] ||
    die "Run this patch on '$REQUIRED_BRANCH'; current branch is '$branch'."

  origin_url="$(git -C "$PROJECT_ROOT" remote get-url origin 2>/dev/null || true)"
  origin_slug="$(normalize_github_slug "$origin_url")"
  [[ "$origin_slug" == "$EXPECTED_ORIGIN_SLUG" ]] ||
    die "Unexpected origin remote: $origin_url"

  git -C "$PROJECT_ROOT" fetch origin "$REQUIRED_BRANCH" --prune

  [[ "$(git -C "$PROJECT_ROOT" rev-parse HEAD)" == "$(git -C "$PROJECT_ROOT" rev-parse "origin/$REQUIRED_BRANCH")" ]] ||
    die "Local develop is not synchronized with origin/develop."

  git -C "$PROJECT_ROOT" diff --cached --quiet ||
    die "The Git index contains staged changes."

  while IFS= read -r status_line; do
    [[ -z "$status_line" ]] && continue
    path="${status_line:3}"

    if [[ "$path" == *" -> "* ]]; then
      path="${path##* -> }"
    fi

    if ! is_allowed_path "$path"; then
      printf '%s\n' "$status_line" >&2
      die "Unexpected working-tree change detected: $path"
    fi
  done < <(git -C "$PROJECT_ROOT" status --porcelain=v1 --untracked-files=all)

  [[ -f "$PROJECT_ROOT/docs/development-setup.md" ]] ||
    die "Expected Patch 003 changes were not found."
  [[ -f "$PROJECT_ROOT/scripts/patches/003-prepare-workstation.sh" ]] ||
    die "Archived Patch 003 was not found."
  [[ -f "$PROJECT_ROOT/scripts/patches/003b-finish-workstation.sh" ]] ||
    die "Archived Patch 003b was not found."
  [[ -f "$PROJECT_ROOT/scripts/patches/003c-generate-bindings-and-finish.sh" ]] ||
    die "Archived Patch 003c was not found."

  ok "Detected only the expected interrupted workstation changes."
}

archive_this_patch() {
  mkdir -p "$PROJECT_ROOT/scripts/patches"
  cp "$SCRIPT_PATH" "$PROJECT_ROOT/$ARCHIVE_RELATIVE_PATH"
  chmod 0755 "$PROJECT_ROOT/$ARCHIVE_RELATIVE_PATH"
  bash -n "$PROJECT_ROOT/$ARCHIVE_RELATIVE_PATH"
  ok "Archived Patch 003d at $ARCHIVE_RELATIVE_PATH."
}

remove_duplicate_if_present() {
  local root_name="$1"
  local archive_name="$2"
  local root_path="$PROJECT_ROOT/$root_name"
  local archive_path="$PROJECT_ROOT/$archive_name"

  if [[ ! -f "$root_path" ]]; then
    return 0
  fi

  [[ -f "$archive_path" ]] ||
    die "Archive missing for duplicate root patch: $archive_name"

  if cmp -s "$root_path" "$archive_path"; then
    rm -f "$root_path"
    ok "Removed duplicate root copy: $root_name"
    return 0
  fi

  die "$root_name differs from its archived copy; refusing to remove it."
}

update_verify_pipeline() {
  cd "$PROJECT_ROOT"

  python3 <<'PY'
from pathlib import Path

path = Path("scripts/sentinel/verify.sh")
text = path.read_text(encoding="utf-8")

old = """info "Building Solidity contracts"
forge build

info "Running Go extension tests"
"""

new = """info "Generating Go contract bindings from Solidity"
./scripts/generate-bindings.sh

info "Running Go extension tests"
"""

if old in text:
    text = text.replace(old, new, 1)
elif new not in text:
    raise SystemExit(
        "Could not find either the old or updated binding-generation block "
        "in scripts/sentinel/verify.sh."
    )

path.write_text(text, encoding="utf-8")
PY

  ok "Verification now generates Go bindings before building deployment tools."
}

run_checks() {
  cd "$PROJECT_ROOT"

  export PATH="/usr/local/go/bin:$HOME/.foundry/bin:$PATH"
  hash -r

  info "Applying canonical Foundry formatting"
  forge fmt

  info "Checking whitespace and maintained shell scripts"
  git diff --check
  bash -n scripts/sentinel/check-dev-env.sh
  bash -n scripts/sentinel/verify.sh
  shellcheck scripts/sentinel/*.sh

  info "Checking the complete development environment"
  ./scripts/sentinel/check-dev-env.sh --strict

  info "Running full verification with binding generation"
  ./scripts/sentinel/verify.sh

  [[ -s tools/pkg/contracts/helloworld/autogen.go ]] ||
    die "Generated Go binding was not created."
  [[ -s tools/pkg/contracts/helloworld/HelloWorldInstructionSender.abi ]] ||
    die "Generated ABI was not created."
  [[ -s tools/pkg/contracts/helloworld/HelloWorldInstructionSender.bin ]] ||
    die "Generated bytecode was not created."

  ok "All environment, generation, build, and test checks passed."
}

verify_final_change_set() {
  cd "$PROJECT_ROOT"

  python3 <<'PY'
import subprocess

allowed = {
    ".github/workflows/quality.yml",
    "README.md",
    "docs/development-setup.md",
    "scripts/sentinel/verify.sh",
    "scripts/patches/003-prepare-workstation.sh",
    "scripts/patches/003b-finish-workstation.sh",
    "scripts/patches/003c-generate-bindings-and-finish.sh",
    "scripts/patches/003d-resume-and-finish.sh",
    "contracts/InstructionSender.sol",
    "contracts/interfaces/ITeeExtensionRegistry.sol",
    "contracts/interfaces/ITeeMachineRegistry.sol",
}

changed = set(
    subprocess.check_output(
        ["git", "diff", "--name-only", "HEAD"],
        text=True,
    ).splitlines()
)

untracked = set(
    subprocess.check_output(
        ["git", "ls-files", "--others", "--exclude-standard"],
        text=True,
    ).splitlines()
)

unexpected = sorted((changed | untracked) - allowed)
if unexpected:
    raise SystemExit(
        "Unexpected files remain after verification:\n  "
        + "\n  ".join(unexpected)
    )

required = {
    ".github/workflows/quality.yml",
    "README.md",
    "docs/development-setup.md",
    "scripts/sentinel/verify.sh",
    "scripts/patches/003-prepare-workstation.sh",
    "scripts/patches/003b-finish-workstation.sh",
    "scripts/patches/003c-generate-bindings-and-finish.sh",
    "scripts/patches/003d-resume-and-finish.sh",
}

missing = sorted(required - (changed | untracked))
if missing:
    raise SystemExit(
        "Expected workstation files are missing:\n  "
        + "\n  ".join(missing)
    )
PY

  ok "Final change set contains only expected files."
}

commit_and_push() {
  cd "$PROJECT_ROOT"

  git add -A
  git diff --cached --check

  [[ -n "$(git diff --cached --name-only)" ]] ||
    die "No changes were staged."

  git commit -m "$COMMIT_MESSAGE"
  git push origin "$REQUIRED_BRANCH"

  if [[ "$(dirname -- "$SCRIPT_PATH")" == "$PROJECT_ROOT" && "$SCRIPT_PATH" != "$PROJECT_ROOT/$ARCHIVE_RELATIVE_PATH" ]]; then
    rm -f "$SCRIPT_PATH"
  fi

  [[ -z "$(git status --porcelain=v1)" ]] ||
    die "Working tree is not clean after commit and push."

  printf '\n'
  ok "Workstation setup completed and pushed successfully."
  printf 'Commit:   %s\n' "$(git rev-parse --short HEAD)"
  printf 'Branch:   %s\n' "$(git branch --show-current)"
  printf 'Go:       %s\n' "$(go version)"
  printf 'Bindings: generated successfully as ignored build artifacts\n'
  printf '\nNext stage: Patch 004 — versioned protocol types and canonical hashing.\n'
}

main() {
  require_command git
  require_command python3
  require_command forge
  require_command go
  require_command shellcheck
  require_command cmp
  require_command jq

  validate_repository_state
  archive_this_patch

  remove_duplicate_if_present \
    "sentinel_patch_003_prepare_workstation.sh" \
    "scripts/patches/003-prepare-workstation.sh"

  remove_duplicate_if_present \
    "sentinel_patch_003b_finish_workstation.sh" \
    "scripts/patches/003b-finish-workstation.sh"

  remove_duplicate_if_present \
    "sentinel_patch_003c_generate_bindings_and_finish.sh" \
    "scripts/patches/003c-generate-bindings-and-finish.sh"

  update_verify_pipeline
  run_checks
  verify_final_change_set
  commit_and_push
}

main "$@"
