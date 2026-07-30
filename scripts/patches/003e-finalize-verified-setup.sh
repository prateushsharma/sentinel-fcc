#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

readonly EXPECTED_ORIGIN_SLUG="prateushsharma/sentinel-fcc"
readonly REQUIRED_BRANCH="develop"
readonly ARCHIVE_RELATIVE_PATH="scripts/patches/003e-finalize-verified-setup.sh"
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

is_expected_path() {
  case "$1" in
    ".github/workflows/quality.yml" \
    | "README.md" \
    | "docs/development-setup.md" \
    | "scripts/sentinel/verify.sh" \
    | "scripts/patches/003-prepare-workstation.sh" \
    | "scripts/patches/003b-finish-workstation.sh" \
    | "scripts/patches/003c-generate-bindings-and-finish.sh" \
    | "scripts/patches/003d-resume-and-finish.sh" \
    | "scripts/patches/003e-finalize-verified-setup.sh" \
    | "contracts/InstructionSender.sol" \
    | "contracts/interfaces/ITeeExtensionRegistry.sol" \
    | "contracts/interfaces/ITeeMachineRegistry.sol" \
    | "sentinel_patch_003d_resume_and_finish.sh" \
    | "sentinel_patch_003e_finalize_verified_setup.sh")
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

    if ! is_expected_path "$path"; then
      printf '%s\n' "$status_line" >&2
      die "Unexpected working-tree change detected: $path"
    fi
  done < <(git -C "$PROJECT_ROOT" status --porcelain=v1 --untracked-files=all)

  for required in \
    docs/development-setup.md \
    scripts/patches/003-prepare-workstation.sh \
    scripts/patches/003b-finish-workstation.sh \
    scripts/patches/003c-generate-bindings-and-finish.sh \
    scripts/patches/003d-resume-and-finish.sh; do
    [[ -f "$PROJECT_ROOT/$required" ]] || die "Expected file missing: $required"
  done

  ok "Detected the expected fully verified, not-yet-committed setup state."
}

archive_this_patch() {
  mkdir -p "$PROJECT_ROOT/scripts/patches"
  cp "$SCRIPT_PATH" "$PROJECT_ROOT/$ARCHIVE_RELATIVE_PATH"
  chmod 0755 "$PROJECT_ROOT/$ARCHIVE_RELATIVE_PATH"
  bash -n "$PROJECT_ROOT/$ARCHIVE_RELATIVE_PATH"
  ok "Archived Patch 003e at $ARCHIVE_RELATIVE_PATH."
}

remove_duplicate_root_patch() {
  local root_name="$1"
  local archive_name="$2"
  local root_path="$PROJECT_ROOT/$root_name"
  local archive_path="$PROJECT_ROOT/$archive_name"

  if [[ ! -f "$root_path" ]]; then
    return 0
  fi

  [[ -f "$archive_path" ]] || die "Missing archived patch: $archive_name"

  if cmp -s "$root_path" "$archive_path"; then
    rm -f "$root_path"
    ok "Removed duplicate root copy: $root_name"
    return 0
  fi

  die "$root_name differs from $archive_name; refusing to remove it."
}

sanitize_local_env_placeholders() {
  local env_file="$PROJECT_ROOT/.env"
  [[ -f "$env_file" ]] || die ".env is missing."

  python3 - "$env_file" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
lines = path.read_text(encoding="utf-8").splitlines()
output = []
changed = []

pattern = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*<your-ngrok-url>.*)$")

for line in lines:
    match = pattern.match(line)
    if not match:
        output.append(line)
        continue

    key = match.group(1)
    output.append(
        f'{key}="" # Set this to your HTTPS ngrok URL before running public-proxy e2e flows.'
    )
    changed.append(key)

path.write_text("\n".join(output) + "\n", encoding="utf-8")

if changed:
    print("Sanitized local placeholder variables: " + ", ".join(changed))
else:
    print("No unsafe ngrok placeholder required sanitization.")
PY

  chmod 0600 "$env_file"

  # Sourcing must now be silent and successful.
  (
    set -a
    # shellcheck disable=SC1091
    source "$env_file"
    set +a
  )

  ok "Local .env can be sourced without interpreting placeholder angle brackets."
}

run_final_verification() {
  cd "$PROJECT_ROOT"
  export PATH="/usr/local/go/bin:$HOME/.foundry/bin:$PATH"
  hash -r

  info "Checking environment"
  ./scripts/sentinel/check-dev-env.sh --strict

  info "Running the complete repository verification suite one final time"
  ./scripts/sentinel/verify.sh

  [[ -s tools/pkg/contracts/helloworld/autogen.go ]] ||
    die "Generated Go bindings are missing after verification."

  ok "All checks passed."
}

verify_change_set() {
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
    "scripts/patches/003e-finalize-verified-setup.sh",
    "contracts/InstructionSender.sol",
    "contracts/interfaces/ITeeExtensionRegistry.sol",
    "contracts/interfaces/ITeeMachineRegistry.sol",
}

changed = set(
    subprocess.check_output(["git", "diff", "--name-only", "HEAD"], text=True).splitlines()
)
untracked = set(
    subprocess.check_output(
        ["git", "ls-files", "--others", "--exclude-standard"], text=True
    ).splitlines()
)

unexpected = sorted((changed | untracked) - allowed)
if unexpected:
    raise SystemExit(
        "Unexpected files remain before commit:\n  " + "\n  ".join(unexpected)
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
    "scripts/patches/003e-finalize-verified-setup.sh",
}

missing = sorted(required - (changed | untracked))
if missing:
    raise SystemExit(
        "Expected setup files are missing:\n  " + "\n  ".join(missing)
    )
PY

  git diff --check
  ok "Final tracked change set is exact and clean."
}

commit_and_push() {
  cd "$PROJECT_ROOT"

  git add -A
  git diff --cached --check

  [[ -n "$(git diff --cached --name-only)" ]] || die "No changes were staged."
  [[ -z "$(git ls-files --others --exclude-standard)" ]] ||
    die "Unexpected untracked files remain."

  git commit -m "$COMMIT_MESSAGE"
  git push origin "$REQUIRED_BRANCH"

  if [[ "$(dirname -- "$SCRIPT_PATH")" == "$PROJECT_ROOT" && "$SCRIPT_PATH" != "$PROJECT_ROOT/$ARCHIVE_RELATIVE_PATH" ]]; then
    rm -f "$SCRIPT_PATH"
  fi

  [[ -z "$(git status --porcelain=v1)" ]] ||
    die "Working tree is not clean after commit and push."

  printf '\n'
  ok "Verified workstation setup committed and pushed."
  printf 'Commit: %s\n' "$(git rev-parse --short HEAD)"
  printf 'Branch: %s\n' "$(git branch --show-current)"
  printf 'Go: %s\n' "$(go version)"
  printf '\nNext stage: Patch 004 — Sentinel protocol types and canonical hashing.\n'
}

main() {
  require_command git
  require_command python3
  require_command go
  require_command forge
  require_command shellcheck
  require_command cmp

  validate_repository_state
  archive_this_patch

  remove_duplicate_root_patch \
    "sentinel_patch_003d_resume_and_finish.sh" \
    "scripts/patches/003d-resume-and-finish.sh"

  remove_duplicate_root_patch \
    "sentinel_patch_003e_finalize_verified_setup.sh" \
    "scripts/patches/003e-finalize-verified-setup.sh"

  sanitize_local_env_placeholders
  run_final_verification
  verify_change_set
  commit_and_push
}

main "$@"
