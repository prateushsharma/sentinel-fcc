#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

readonly EXPECTED_ORIGIN_SLUG="prateushsharma/sentinel-fcc"
readonly REQUIRED_BRANCH="develop"
readonly ARCHIVE_RELATIVE_PATH="scripts/patches/003b-finish-workstation.sh"
readonly ORIGINAL_PATCH_ROOT="sentinel_patch_003_prepare_workstation.sh"
readonly ORIGINAL_PATCH_ARCHIVE="scripts/patches/003-prepare-workstation.sh"
readonly COMMIT_MESSAGE="chore(dev): prepare reproducible workstation setup"

SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/$(basename -- "${BASH_SOURCE[0]}")"
SCRIPT_BASENAME="$(basename -- "$SCRIPT_PATH")"
PROJECT_ROOT="${1:-$(pwd)}"
PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd)"

info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

trap 'die "Recovery patch failed at line $LINENO while running: $BASH_COMMAND"' ERR

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

is_allowed_dirty_path() {
  case "$1" in
    ".github/workflows/quality.yml" \
    | "README.md" \
    | "docs/development-setup.md" \
    | "scripts/sentinel/verify.sh" \
    | "scripts/patches/003-prepare-workstation.sh" \
    | "sentinel_patch_003_prepare_workstation.sh" \
    | "sentinel_patch_003b_finish_workstation.sh")
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
    die "The index already contains staged changes. Unstage them before running this recovery patch."

  while IFS= read -r status_line; do
    [[ -z "$status_line" ]] && continue
    path="${status_line:3}"

    if [[ "$path" == *" -> "* ]]; then
      path="${path##* -> }"
    fi

    if ! is_allowed_dirty_path "$path"; then
      printf '%s\n' "$status_line" >&2
      die "Unexpected working-tree change detected: $path"
    fi
  done < <(git -C "$PROJECT_ROOT" status --porcelain=v1 --untracked-files=all)

  [[ -f "$PROJECT_ROOT/docs/development-setup.md" ]] ||
    die "Patch 003 changes were not found. Expected docs/development-setup.md."

  [[ -f "$PROJECT_ROOT/$ORIGINAL_PATCH_ARCHIVE" ]] ||
    die "Archived Patch 003 was not found."

  ok "Detected the expected interrupted Patch 003 state only."
}

archive_recovery_patch() {
  mkdir -p "$PROJECT_ROOT/scripts/patches"
  cp "$SCRIPT_PATH" "$PROJECT_ROOT/$ARCHIVE_RELATIVE_PATH"
  chmod 0755 "$PROJECT_ROOT/$ARCHIVE_RELATIVE_PATH"
  bash -n "$PROJECT_ROOT/$ARCHIVE_RELATIVE_PATH"
  ok "Archived recovery patch at $ARCHIVE_RELATIVE_PATH."
}

remove_duplicate_root_patch() {
  local root_patch="$PROJECT_ROOT/$ORIGINAL_PATCH_ROOT"
  local archived_patch="$PROJECT_ROOT/$ORIGINAL_PATCH_ARCHIVE"

  if [[ ! -f "$root_patch" ]]; then
    return
  fi

  if cmp -s "$root_patch" "$archived_patch"; then
    rm -f "$root_patch"
    ok "Removed duplicate root copy of Patch 003."
  else
    die "$ORIGINAL_PATCH_ROOT differs from its archived copy; refusing to remove it."
  fi
}

format_and_verify() {
  cd "$PROJECT_ROOT"

  export PATH="/usr/local/go/bin:$HOME/.foundry/bin:$PATH"
  hash -r

  info "Applying canonical Foundry formatting"
  forge fmt

  info "Checking repository patch integrity"
  git diff --check

  info "Validating maintained shell scripts"
  bash -n scripts/sentinel/check-dev-env.sh
  bash -n scripts/sentinel/verify.sh
  bash -n "$ORIGINAL_PATCH_ARCHIVE"
  bash -n "$ARCHIVE_RELATIVE_PATH"
  shellcheck scripts/sentinel/*.sh

  info "Rechecking the complete local development environment"
  ./scripts/sentinel/check-dev-env.sh --strict

  info "Running the complete non-chain repository verification suite"
  ./scripts/sentinel/verify.sh

  ok "Formatting and all verification checks passed."
}

stage_expected_files() {
  cd "$PROJECT_ROOT"

  local expected=(
    ".github/workflows/quality.yml"
    "README.md"
    "docs/development-setup.md"
    "scripts/sentinel/verify.sh"
    "scripts/patches/003-prepare-workstation.sh"
    "$ARCHIVE_RELATIVE_PATH"
    "contracts/InstructionSender.sol"
    "contracts/interfaces/ITeeExtensionRegistry.sol"
    "contracts/interfaces/ITeeMachineRegistry.sol"
  )

  git add -- "${expected[@]}"
  git diff --cached --check

  local unstaged
  unstaged="$(git status --porcelain=v1 --untracked-files=all | awk '$1 !~ /^[AMDRC][AMDRC]$/ {print}')"
  if [[ -n "$unstaged" ]]; then
    printf '%s\n' "$unstaged" >&2
    die "Unexpected unstaged or untracked changes remain after staging."
  fi

  [[ -n "$(git diff --cached --name-only)" ]] ||
    die "No changes were staged."

  ok "Staged only the expected workstation and formatting changes."
}

commit_and_push() {
  cd "$PROJECT_ROOT"

  git commit -m "$COMMIT_MESSAGE"
  git push origin "$REQUIRED_BRANCH"

  if [[ "$(dirname -- "$SCRIPT_PATH")" == "$PROJECT_ROOT" && "$SCRIPT_PATH" != "$PROJECT_ROOT/$ARCHIVE_RELATIVE_PATH" ]]; then
    rm -f "$SCRIPT_PATH"
  fi

  [[ -z "$(git status --porcelain=v1)" ]] ||
    die "Working tree is not clean after commit and push."

  printf '\n'
  ok "Patch 003 recovery completed and pushed."
  printf 'Commit: %s\n' "$(git rev-parse --short HEAD)"
  printf 'Go: %s\n' "$(go version)"
  printf 'Branch: %s\n' "$(git branch --show-current)"
  printf '\nNext stage: Patch 004 — versioned protocol types and canonical hashing.\n'
}

main() {
  require_command git
  require_command forge
  require_command go
  require_command shellcheck
  require_command cmp
  require_command awk

  validate_repository_state
  archive_recovery_patch
  remove_duplicate_root_patch
  format_and_verify
  stage_expected_files
  commit_and_push
}

main "$@"
