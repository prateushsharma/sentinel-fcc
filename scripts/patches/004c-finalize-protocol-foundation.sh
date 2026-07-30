#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

readonly EXPECTED_ORIGIN_SLUG="prateushsharma/sentinel-fcc"
readonly BASE_BRANCH="develop"
readonly FEATURE_BRANCH="feat/protocol-v1-foundation"
readonly ARCHIVE_RELATIVE_PATH="scripts/patches/004c-finalize-protocol-foundation.sh"

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
    | "contracts/libraries/SentinelProtocol.sol" \
    | "docs/protocol-v1.md" \
    | "go/cmd/protocol-vectors/main.go" \
    | "go/internal/protocolvectors/vectors.go" \
    | "go/pkg/protocol/doc.go" \
    | "go/pkg/protocol/hashing.go" \
    | "go/pkg/protocol/hashing_test.go" \
    | "go/pkg/protocol/risk.go" \
    | "go/pkg/protocol/types.go" \
    | "go/pkg/protocol/validation.go" \
    | "go/pkg/protocol/validation_test.go" \
    | "go/pkg/protocol/version.go" \
    | "scripts/patches/004-protocol-v1-foundation.sh" \
    | "scripts/patches/004b-resume-protocol-foundation.sh" \
    | "scripts/patches/004c-finalize-protocol-foundation.sh" \
    | "scripts/sentinel/check-protocol-vectors.sh" \
    | "scripts/sentinel/verify.sh" \
    | "test/SentinelProtocol.t.sol" \
    | "testdata/protocol/v1.json" \
    | "sentinel_patch_004c_finalize_protocol_foundation.sh")
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
    contracts/libraries/SentinelProtocol.sol \
    go/pkg/protocol/hashing.go \
    test/SentinelProtocol.t.sol \
    testdata/protocol/v1.json \
    scripts/sentinel/check-protocol-vectors.sh \
    scripts/patches/004-protocol-v1-foundation.sh \
    scripts/patches/004b-resume-protocol-foundation.sh; do
    [[ -f "$PROJECT_ROOT/$required" ]] || die "Expected Patch 004 file missing: $required"
  done

  ok "Detected the expected interrupted Patch 004 state."
}

archive_this_patch() {
  mkdir -p "$PROJECT_ROOT/scripts/patches"
  cp "$SCRIPT_PATH" "$PROJECT_ROOT/$ARCHIVE_RELATIVE_PATH"
  chmod 0755 "$PROJECT_ROOT/$ARCHIVE_RELATIVE_PATH"
  bash -n "$PROJECT_ROOT/$ARCHIVE_RELATIVE_PATH"
  ok "Archived Patch 004c."
}

replace_vector_checker() {
  cat > "$PROJECT_ROOT/scripts/sentinel/check-protocol-vectors.sh" <<'EOF'
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
EOF

  chmod 0755 "$PROJECT_ROOT/scripts/sentinel/check-protocol-vectors.sh"
  bash -n "$PROJECT_ROOT/scripts/sentinel/check-protocol-vectors.sh"

  ok "Replaced brittle Solidity source parsing with executable parity tests."
}

remove_root_script_copy() {
  if [[ "$(dirname -- "$SCRIPT_PATH")" == "$PROJECT_ROOT" && "$SCRIPT_PATH" != "$PROJECT_ROOT/$ARCHIVE_RELATIVE_PATH" ]]; then
    rm -f "$SCRIPT_PATH"
    ok "Removed duplicate root copy of Patch 004c."
  fi
}

run_full_verification() {
  cd "$PROJECT_ROOT"
  export PATH="/usr/local/go/bin:$HOME/.foundry/bin:$PATH"
  hash -r

  info "Formatting protocol sources"
  gofmt -w go/pkg/protocol go/internal/protocolvectors go/cmd/protocol-vectors
  forge fmt

  info "Checking scripts and whitespace"
  bash -n scripts/sentinel/check-protocol-vectors.sh
  bash -n "$ARCHIVE_RELATIVE_PATH"
  shellcheck scripts/sentinel/*.sh
  git diff --check

  info "Running complete Sentinel verification"
  ./scripts/sentinel/verify.sh

  ok "All protocol, vector, Solidity, Go, and scaffold checks passed."
}

verify_change_set() {
  cd "$PROJECT_ROOT"

  python3 <<'PY'
import subprocess

allowed = {
    "README.md",
    "contracts/libraries/SentinelProtocol.sol",
    "docs/protocol-v1.md",
    "go/cmd/protocol-vectors/main.go",
    "go/internal/protocolvectors/vectors.go",
    "go/pkg/protocol/doc.go",
    "go/pkg/protocol/hashing.go",
    "go/pkg/protocol/hashing_test.go",
    "go/pkg/protocol/risk.go",
    "go/pkg/protocol/types.go",
    "go/pkg/protocol/validation.go",
    "go/pkg/protocol/validation_test.go",
    "go/pkg/protocol/version.go",
    "scripts/patches/004-protocol-v1-foundation.sh",
    "scripts/patches/004b-resume-protocol-foundation.sh",
    "scripts/patches/004c-finalize-protocol-foundation.sh",
    "scripts/sentinel/check-protocol-vectors.sh",
    "scripts/sentinel/verify.sh",
    "test/SentinelProtocol.t.sol",
    "testdata/protocol/v1.json",
}

status = subprocess.check_output(
    ["git", "status", "--porcelain=v1", "--untracked-files=all"],
    text=True,
).splitlines()

unexpected = [line for line in status if line[3:] not in allowed]
if unexpected:
    raise SystemExit(
        "Unexpected files in final Patch 004 change set:\n  "
        + "\n  ".join(unexpected)
    )

required = {
    "contracts/libraries/SentinelProtocol.sol",
    "go/pkg/protocol/hashing.go",
    "scripts/sentinel/check-protocol-vectors.sh",
    "test/SentinelProtocol.t.sol",
    "testdata/protocol/v1.json",
    "scripts/patches/004c-finalize-protocol-foundation.sh",
}

present = {line[3:] for line in status}
missing = sorted(required - present)
if missing:
    raise SystemExit(
        "Expected Patch 004 files are missing:\n  "
        + "\n  ".join(missing)
    )
PY

  ok "Final Patch 004 change set is exact."
}

commit_atomic_history() {
  cd "$PROJECT_ROOT"

  git add \
    go/pkg/protocol/doc.go \
    go/pkg/protocol/version.go \
    go/pkg/protocol/types.go \
    go/pkg/protocol/risk.go \
    go/pkg/protocol/validation.go \
    go/pkg/protocol/hashing.go \
    contracts/libraries/SentinelProtocol.sol
  git diff --cached --check
  git commit -m "feat(protocol): add versioned canonical protocol types"

  git add \
    go/pkg/protocol/hashing_test.go \
    go/pkg/protocol/validation_test.go \
    go/internal/protocolvectors/vectors.go \
    go/cmd/protocol-vectors/main.go \
    testdata/protocol/v1.json \
    test/SentinelProtocol.t.sol \
    scripts/sentinel/check-protocol-vectors.sh \
    scripts/sentinel/verify.sh
  git diff --cached --check
  git commit -m "test(protocol): add cross-language hashing vectors"

  git add README.md docs/protocol-v1.md
  git diff --cached --check
  git commit -m "docs(protocol): specify v1 canonical encoding"

  git add \
    scripts/patches/004-protocol-v1-foundation.sh \
    scripts/patches/004b-resume-protocol-foundation.sh \
    "$ARCHIVE_RELATIVE_PATH"
  git diff --cached --check
  git commit -m "chore(project): archive protocol foundation patches"

  [[ -z "$(git status --porcelain=v1)" ]] ||
    die "Working tree is not clean after Patch 004 commits."

  ok "Created four atomic protocol-foundation commits."
}

push_feature_branch() {
  cd "$PROJECT_ROOT"
  git push -u origin "$FEATURE_BRANCH"

  printf '\n'
  ok "Patch 004 completed and pushed successfully."
  printf 'Branch: %s\n' "$FEATURE_BRANCH"
  printf 'Head:   %s\n' "$(git rev-parse --short HEAD)"
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
  require_command diff

  validate_repository_state
  archive_this_patch
  replace_vector_checker
  remove_root_script_copy
  run_full_verification
  verify_change_set
  commit_atomic_history
  push_feature_branch
}

main "$@"
