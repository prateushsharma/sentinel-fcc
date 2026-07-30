#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

readonly EXPECTED_ORIGIN_SLUG="prateushsharma/sentinel-fcc"
readonly EXPECTED_UPSTREAM_SLUG="flare-foundation/fce-extension-scaffold"
readonly ARCHIVE_RELATIVE_PATH="scripts/patches/002-clean-repository-history.sh"

SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/$(basename -- "${BASH_SOURCE[0]}")"
SCRIPT_BASENAME="$(basename -- "$SCRIPT_PATH")"
PROJECT_ROOT="${1:-$(pwd)}"
PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd)"

ORIGINAL_HEAD=""
ORIGINAL_BRANCH=""
BACKUP_BRANCH=""
BACKUP_BUNDLE=""
PUSH_COMPLETE=false
CHANGES_STARTED=false

info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

rollback_if_needed() {
  local rc=$?
  if (( rc != 0 )) && [[ "$CHANGES_STARTED" == true ]] && [[ "$PUSH_COMPLETE" != true ]] && [[ -n "$ORIGINAL_HEAD" ]]; then
    warn "Restoring the original working tree because the remote rewrite did not complete."
    git -C "$PROJECT_ROOT" reset --hard "$ORIGINAL_HEAD" >/dev/null 2>&1 || true
  fi
  exit "$rc"
}
trap rollback_if_needed EXIT

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

ensure_only_runner_script_is_untracked() {
  local line
  local allowed_untracked=false

  if [[ "$(dirname -- "$SCRIPT_PATH")" == "$PROJECT_ROOT" ]]; then
    allowed_untracked=true
  fi

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    if [[ "$allowed_untracked" == true && "$line" == "?? $SCRIPT_BASENAME" ]]; then
      continue
    fi

    printf '%s\n' "$line" >&2
    die "Working tree contains unrelated changes. Commit or remove them before running this patch."
  done < <(git -C "$PROJECT_ROOT" status --porcelain=v1 --untracked-files=all)
}

configure_git_identity() {
  local name email
  name="$(git -C "$PROJECT_ROOT" config user.name || true)"
  email="$(git -C "$PROJECT_ROOT" config user.email || true)"

  [[ -n "$name" ]] || die "Git user.name is not configured."
  [[ -n "$email" ]] || die "Git user.email is not configured."

  ok "Git author: $name <$email>"
}

create_backup() {
  local timestamp
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  BACKUP_BRANCH="backup/pre-history-cleanup-$timestamp"
  BACKUP_BUNDLE="$HOME/.sentinel-backups/sentinel-fcc-before-history-cleanup-$timestamp.bundle"

  mkdir -p "$(dirname -- "$BACKUP_BUNDLE")"

  git -C "$PROJECT_ROOT" branch "$BACKUP_BRANCH" "$ORIGINAL_HEAD"
  git -C "$PROJECT_ROOT" bundle create "$BACKUP_BUNDLE" --all >/dev/null

  ok "Created local backup branch: $BACKUP_BRANCH"
  ok "Created full backup bundle: $BACKUP_BUNDLE"
}

add_attribution_and_archive_patch() {
  local upstream_sha
  upstream_sha="$(git -C "$PROJECT_ROOT" rev-parse flare-upstream/main)"

  mkdir -p "$PROJECT_ROOT/scripts/patches"
  cp "$SCRIPT_PATH" "$PROJECT_ROOT/$ARCHIVE_RELATIVE_PATH"
  chmod 0755 "$PROJECT_ROOT/$ARCHIVE_RELATIVE_PATH"

  cat > "$PROJECT_ROOT/NOTICE" <<EOF
SentinelFCC Upstream Attribution
================================

SentinelFCC was initialized from the Flare Foundation FCE Extension Scaffold:

  Repository: https://github.com/flare-foundation/fce-extension-scaffold
  Upstream commit: $upstream_sha

The scaffold provides the base confidential-compute extension infrastructure.
SentinelFCC-specific protocol logic, policy evaluation, transaction analysis,
onchain enforcement, SDKs, integrations, tests, and documentation are developed
in this repository.

Upstream files and dependencies retain their original copyright notices and
licensing terms. This notice does not replace or modify those terms.
EOF

  UPSTREAM_SHA="$upstream_sha" python3 <<'PY'
from pathlib import Path
import os

readme = Path("README.md")
text = readme.read_text()

heading = "## Upstream foundation"
section = f"""## Upstream foundation

SentinelFCC was initialized from the [Flare Foundation FCE Extension Scaffold](https://github.com/flare-foundation/fce-extension-scaffold) at upstream commit `{os.environ["UPSTREAM_SHA"]}`. The scaffold supplies the base FCC extension infrastructure; Sentinel-specific protocol logic, confidential policy evaluation, transaction analysis, onchain enforcement, SDKs, integrations, tests, and product code are developed in this repository.

The complete attribution is recorded in [`NOTICE`](NOTICE), and the upstream remote remains configured as `flare-upstream`.

"""

if heading not in text:
    marker = "## Development\n"
    if marker not in text:
        raise SystemExit("README.md does not contain the expected Development heading.")
    text = text.replace(marker, section + marker, 1)
    readme.write_text(text)
PY

  git -C "$PROJECT_ROOT" add README.md NOTICE "$ARCHIVE_RELATIVE_PATH"
  git -C "$PROJECT_ROOT" diff --cached --check
  bash -n "$PROJECT_ROOT/$ARCHIVE_RELATIVE_PATH"

  ok "Added explicit Flare scaffold attribution."
  ok "Archived this patch at $ARCHIVE_RELATIVE_PATH."
}

create_clean_root_commit() {
  local tree commit_message commit_body

  tree="$(git -C "$PROJECT_ROOT" write-tree)"
  commit_message="chore: initialize SentinelFCC project"
  commit_body="Initialize SentinelFCC from the Flare FCC extension scaffold.

Preserve explicit upstream attribution while establishing a clean project-owned
history for hackathon development and future security engineering."

  NEW_ROOT_COMMIT="$(
    {
      printf '%s\n\n' "$commit_message"
      printf '%s\n' "$commit_body"
    } | git -C "$PROJECT_ROOT" commit-tree "$tree"
  )"

  [[ -n "$NEW_ROOT_COMMIT" ]] || die "Failed to create the clean root commit."

  if git -C "$PROJECT_ROOT" cat-file -p "$NEW_ROOT_COMMIT" | grep -q '^parent '; then
    die "Safety check failed: the new commit unexpectedly has a parent."
  fi

  ok "Created clean root commit: $NEW_ROOT_COMMIT"
}

force_push_clean_history() {
  local remote_main remote_develop

  remote_main="$(git -C "$PROJECT_ROOT" rev-parse refs/remotes/origin/main)"
  remote_develop="$(git -C "$PROJECT_ROOT" rev-parse refs/remotes/origin/develop)"

  info "Replacing remote main and develop atomically using force-with-lease"

  git -C "$PROJECT_ROOT" push --atomic origin \
    "$NEW_ROOT_COMMIT:refs/heads/main" \
    "$NEW_ROOT_COMMIT:refs/heads/develop" \
    "--force-with-lease=refs/heads/main:$remote_main" \
    "--force-with-lease=refs/heads/develop:$remote_develop"

  PUSH_COMPLETE=true
  ok "Remote history replaced safely."
}

update_local_branches() {
  local old_main old_develop

  old_main="$(git -C "$PROJECT_ROOT" rev-parse refs/heads/main)"
  old_develop="$(git -C "$PROJECT_ROOT" rev-parse refs/heads/develop)"

  git -C "$PROJECT_ROOT" update-ref refs/heads/main "$NEW_ROOT_COMMIT" "$old_main"
  git -C "$PROJECT_ROOT" update-ref refs/heads/develop "$NEW_ROOT_COMMIT" "$old_develop"

  git -C "$PROJECT_ROOT" switch develop >/dev/null
  git -C "$PROJECT_ROOT" reset --hard "$NEW_ROOT_COMMIT" >/dev/null
  git -C "$PROJECT_ROOT" fetch origin --prune >/dev/null
  git -C "$PROJECT_ROOT" branch --set-upstream-to=origin/main main >/dev/null
  git -C "$PROJECT_ROOT" branch --set-upstream-to=origin/develop develop >/dev/null

  if [[ "$(dirname -- "$SCRIPT_PATH")" == "$PROJECT_ROOT" && "$SCRIPT_PATH" != "$PROJECT_ROOT/$ARCHIVE_RELATIVE_PATH" ]]; then
    rm -f "$SCRIPT_PATH"
  fi

  ok "Local main and develop now point to the clean root commit."
}

verify_result() {
  local main_sha develop_sha origin_main_sha origin_develop_sha commit_count

  main_sha="$(git -C "$PROJECT_ROOT" rev-parse main)"
  develop_sha="$(git -C "$PROJECT_ROOT" rev-parse develop)"
  origin_main_sha="$(git -C "$PROJECT_ROOT" rev-parse origin/main)"
  origin_develop_sha="$(git -C "$PROJECT_ROOT" rev-parse origin/develop)"
  commit_count="$(git -C "$PROJECT_ROOT" rev-list --count main)"

  [[ "$main_sha" == "$NEW_ROOT_COMMIT" ]] || die "Local main verification failed."
  [[ "$develop_sha" == "$NEW_ROOT_COMMIT" ]] || die "Local develop verification failed."
  [[ "$origin_main_sha" == "$NEW_ROOT_COMMIT" ]] || die "Remote main verification failed."
  [[ "$origin_develop_sha" == "$NEW_ROOT_COMMIT" ]] || die "Remote develop verification failed."
  [[ "$commit_count" == "1" ]] || die "Expected main to contain exactly one commit; found $commit_count."
  [[ -z "$(git -C "$PROJECT_ROOT" status --porcelain=v1)" ]] || die "Working tree is not clean after rewrite."

  git -C "$PROJECT_ROOT" fsck --no-progress --connectivity-only >/dev/null

  printf '\n'
  ok "History cleanup completed."
  printf 'Clean root commit: %s\n' "$NEW_ROOT_COMMIT"
  printf 'Backup branch:     %s\n' "$BACKUP_BRANCH"
  printf 'Backup bundle:     %s\n' "$BACKUP_BUNDLE"
  printf '\nCurrent public history:\n'
  git -C "$PROJECT_ROOT" log --oneline --decorate --all \
    --exclude="refs/heads/backup/*" \
    --exclude="refs/remotes/flare-upstream/*" \
    -5
  printf '\nPublic branch contributor summary:\n'
  git -C "$PROJECT_ROOT" shortlog -sne main
  printf '\n'
  warn "GitHub contributor statistics can take some time to recalculate."
}

main() {
  require_command git
  require_command python3
  require_command grep
  require_command date

  [[ -d "$PROJECT_ROOT/.git" ]] || die "Not a Git repository: $PROJECT_ROOT"

  local origin_url upstream_url origin_slug upstream_slug
  origin_url="$(git -C "$PROJECT_ROOT" remote get-url origin 2>/dev/null || true)"
  upstream_url="$(git -C "$PROJECT_ROOT" remote get-url flare-upstream 2>/dev/null || true)"
  origin_slug="$(normalize_github_slug "$origin_url")"
  upstream_slug="$(normalize_github_slug "$upstream_url")"

  [[ "$origin_slug" == "$EXPECTED_ORIGIN_SLUG" ]] ||
    die "Unexpected origin remote: $origin_url"
  [[ "$upstream_slug" == "$EXPECTED_UPSTREAM_SLUG" ]] ||
    die "Unexpected flare-upstream remote: $upstream_url"

  configure_git_identity
  ensure_only_runner_script_is_untracked

  ORIGINAL_HEAD="$(git -C "$PROJECT_ROOT" rev-parse HEAD)"
  ORIGINAL_BRANCH="$(git -C "$PROJECT_ROOT" branch --show-current)"

  [[ "$ORIGINAL_BRANCH" == "main" || "$ORIGINAL_BRANCH" == "develop" ]] ||
    die "Run this patch from main or develop, not $ORIGINAL_BRANCH."

  info "Fetching current remote branch state"
  git -C "$PROJECT_ROOT" fetch origin main develop --prune

  local local_main local_develop remote_main remote_develop
  local_main="$(git -C "$PROJECT_ROOT" rev-parse refs/heads/main)"
  local_develop="$(git -C "$PROJECT_ROOT" rev-parse refs/heads/develop)"
  remote_main="$(git -C "$PROJECT_ROOT" rev-parse refs/remotes/origin/main)"
  remote_develop="$(git -C "$PROJECT_ROOT" rev-parse refs/remotes/origin/develop)"

  [[ "$local_main" == "$local_develop" ]] ||
    die "main and develop have diverged. Refusing to discard either branch."
  [[ "$local_main" == "$remote_main" ]] ||
    die "Local main differs from origin/main. Pull or resolve it first."
  [[ "$local_develop" == "$remote_develop" ]] ||
    die "Local develop differs from origin/develop. Pull or resolve it first."
  [[ "$ORIGINAL_HEAD" == "$local_main" ]] ||
    die "Current HEAD is not the shared main/develop commit."

  create_backup

  CHANGES_STARTED=true
  cd "$PROJECT_ROOT"
  add_attribution_and_archive_patch
  create_clean_root_commit
  force_push_clean_history
  update_local_branches
  verify_result
}

main "$@"
