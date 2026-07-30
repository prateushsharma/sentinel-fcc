#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

readonly EXPECTED_ORIGIN_SLUG="prateushsharma/sentinel-fcc"
readonly REQUIRED_BRANCH="develop"
readonly GO_VERSION="1.25.12"
readonly GO_RELEASE_API="https://go.dev/dl/?mode=json&include=all"
readonly ARCHIVE_RELATIVE_PATH="scripts/patches/003-prepare-workstation.sh"
readonly COMMIT_MESSAGE="chore(dev): prepare reproducible workstation setup"

SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/$(basename -- "${BASH_SOURCE[0]}")"
SCRIPT_BASENAME="$(basename -- "$SCRIPT_PATH")"
PROJECT_ROOT="${1:-$(pwd)}"
PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd)"

TEMP_DIR=""
GO_BACKUP_PATH=""

info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

cleanup() {
  if [[ -n "${TEMP_DIR:-}" && -d "$TEMP_DIR" ]]; then
    rm -rf -- "$TEMP_DIR"
  fi
}
trap cleanup EXIT
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

ensure_safe_repository_state() {
  local current_branch origin_url origin_slug status_line
  current_branch="$(git -C "$PROJECT_ROOT" branch --show-current)"
  [[ "$current_branch" == "$REQUIRED_BRANCH" ]] ||
    die "Run this patch on '$REQUIRED_BRANCH'; current branch is '$current_branch'."

  origin_url="$(git -C "$PROJECT_ROOT" remote get-url origin 2>/dev/null || true)"
  origin_slug="$(normalize_github_slug "$origin_url")"
  [[ "$origin_slug" == "$EXPECTED_ORIGIN_SLUG" ]] ||
    die "Unexpected origin remote: $origin_url"

  git -C "$PROJECT_ROOT" fetch origin "$REQUIRED_BRANCH" --prune
  [[ "$(git -C "$PROJECT_ROOT" rev-parse HEAD)" == "$(git -C "$PROJECT_ROOT" rev-parse "origin/$REQUIRED_BRANCH")" ]] ||
    die "Local develop is not synchronized with origin/develop."

  while IFS= read -r status_line; do
    [[ -z "$status_line" ]] && continue
    if [[ "$(dirname -- "$SCRIPT_PATH")" == "$PROJECT_ROOT" && "$status_line" == "?? $SCRIPT_BASENAME" ]]; then
      continue
    fi
    printf '%s\n' "$status_line" >&2
    die "Working tree contains unrelated changes."
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

detect_go_arch() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'amd64' ;;
    aarch64|arm64) printf 'arm64' ;;
    *) die "Unsupported CPU architecture for this setup script: $(uname -m)" ;;
  esac
}

install_system_packages() {
  info "Installing required workstation packages"
  sudo apt-get update
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates \
    curl \
    jq \
    shellcheck

  ok "Installed curl, jq, CA certificates, and ShellCheck."
}

resolve_go_release() {
  local arch="$1"
  local metadata_file="$2"

  curl --fail --silent --show-error --location \
    "$GO_RELEASE_API" \
    --output "$metadata_file"

  python3 - "$metadata_file" "$GO_VERSION" "$arch" <<'PY'
import json
import sys

metadata_path, version, arch = sys.argv[1:]
wanted_version = f"go{version}"

with open(metadata_path, "r", encoding="utf-8") as handle:
    releases = json.load(handle)

for release in releases:
    if release.get("version") != wanted_version:
        continue
    for artifact in release.get("files", []):
        if (
            artifact.get("os") == "linux"
            and artifact.get("arch") == arch
            and artifact.get("kind") == "archive"
        ):
            filename = artifact.get("filename")
            sha256 = artifact.get("sha256")
            if not filename or not sha256:
                raise SystemExit("Official Go metadata is missing filename or SHA-256.")
            print(filename)
            print(sha256)
            raise SystemExit(0)

raise SystemExit(
    f"Could not find official Linux/{arch} archive metadata for Go {version}."
)
PY
}

install_go() {
  local arch metadata_file release_data filename expected_sha archive_path
  local timestamp installed_version

  arch="$(detect_go_arch)"
  metadata_file="$TEMP_DIR/go-releases.json"

  info "Resolving official Go $GO_VERSION release metadata for linux/$arch"
  release_data="$(resolve_go_release "$arch" "$metadata_file")"
  filename="$(printf '%s\n' "$release_data" | sed -n '1p')"
  expected_sha="$(printf '%s\n' "$release_data" | sed -n '2p')"

  [[ -n "$filename" && -n "$expected_sha" ]] ||
    die "Failed to resolve the Go archive and checksum."

  archive_path="$TEMP_DIR/$filename"

  info "Downloading $filename from go.dev"
  curl --fail --show-error --location \
    "https://go.dev/dl/$filename" \
    --output "$archive_path"

  info "Verifying the official SHA-256 checksum"
  printf '%s  %s\n' "$expected_sha" "$archive_path" | sha256sum --check -

  mkdir -p "$TEMP_DIR/extracted"
  tar -C "$TEMP_DIR/extracted" -xzf "$archive_path"
  [[ -x "$TEMP_DIR/extracted/go/bin/go" ]] ||
    die "Downloaded archive did not contain the expected Go binary."

  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  GO_BACKUP_PATH="/usr/local/go.sentinel-backup-$timestamp"

  if [[ -e /usr/local/go ]]; then
    info "Temporarily backing up the existing /usr/local/go"
    sudo mv /usr/local/go "$GO_BACKUP_PATH"
  else
    GO_BACKUP_PATH=""
  fi

  if ! sudo mv "$TEMP_DIR/extracted/go" /usr/local/go; then
    if [[ -n "$GO_BACKUP_PATH" && -e "$GO_BACKUP_PATH" ]]; then
      sudo mv "$GO_BACKUP_PATH" /usr/local/go
    fi
    die "Failed to install Go under /usr/local/go."
  fi

  export PATH="/usr/local/go/bin:$PATH"
  hash -r

  installed_version="$(/usr/local/go/bin/go version | awk '{print $3}' | sed 's/^go//')"
  if [[ "$installed_version" != "$GO_VERSION" ]]; then
    sudo rm -rf /usr/local/go
    if [[ -n "$GO_BACKUP_PATH" && -e "$GO_BACKUP_PATH" ]]; then
      sudo mv "$GO_BACKUP_PATH" /usr/local/go
    fi
    die "Go installation verification failed; expected $GO_VERSION, found $installed_version."
  fi

  if [[ -n "$GO_BACKUP_PATH" && -e "$GO_BACKUP_PATH" ]]; then
    sudo rm -rf -- "$GO_BACKUP_PATH"
    GO_BACKUP_PATH=""
  fi

  ok "$(/usr/local/go/bin/go version)"
}

ensure_shell_path() {
  local profile="$HOME/.profile"
  local marker_start="# BEGIN SENTINEL GO PATH"
  local marker_end="# END SENTINEL GO PATH"

  touch "$profile"

  python3 - "$profile" "$marker_start" "$marker_end" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
start, end = sys.argv[2], sys.argv[3]
text = path.read_text(encoding="utf-8")

block = f"""{start}
if [ -d /usr/local/go/bin ]; then
    case ":$PATH:" in
        *:/usr/local/go/bin:*) ;;
        *) PATH="/usr/local/go/bin:$PATH" ;;
    esac
fi
export PATH
{end}
"""

if start in text and end in text:
    before, remainder = text.split(start, 1)
    _, after = remainder.split(end, 1)
    text = before.rstrip() + "\n\n" + block + after.lstrip("\n")
else:
    text = text.rstrip() + "\n\n" + block

path.write_text(text, encoding="utf-8")
PY

  ok "Ensured /usr/local/go/bin is present in ~/.profile."
}

ensure_local_env() {
  local env_file="$PROJECT_ROOT/.env"

  if [[ ! -f "$env_file" ]]; then
    cp "$PROJECT_ROOT/.env.example" "$env_file"
    info "Created .env from .env.example"
  fi

  python3 - "$env_file" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
lines = path.read_text(encoding="utf-8").splitlines()
output = []
found = False

for line in lines:
    if line.startswith("LANGUAGE="):
        output.append("LANGUAGE=go")
        found = True
    else:
        output.append(line)

if not found:
    output.append("LANGUAGE=go")

path.write_text("\n".join(output) + "\n", encoding="utf-8")
PY

  chmod 0600 "$env_file"
  ok "Configured local .env with LANGUAGE=go."
}

write_repository_changes() {
  mkdir -p "$PROJECT_ROOT/scripts/patches"
  cp "$SCRIPT_PATH" "$PROJECT_ROOT/$ARCHIVE_RELATIVE_PATH"
  chmod 0755 "$PROJECT_ROOT/$ARCHIVE_RELATIVE_PATH"

  cat > "$PROJECT_ROOT/docs/development-setup.md" <<'EOF'
# Development Workstation Setup

SentinelFCC currently standardizes local extension development on:

- Ubuntu or another compatible Linux environment;
- Go 1.25.12;
- Docker with an accessible daemon;
- Foundry (`forge` and `cast`);
- `jq`;
- ShellCheck;
- Git.

The project intentionally uses the latest patch release in the Go 1.25 line rather than upgrading to a new language minor without a reviewed compatibility change.

## Automated setup

From the repository root:

```bash
./scripts/patches/003-prepare-workstation.sh
```

The script obtains release metadata from the official Go download API, verifies the archive SHA-256 value, safely replaces `/usr/local/go`, configures the local ignored `.env`, runs project verification, and commits the tracked setup changes.

## Verification

```bash
./scripts/sentinel/check-dev-env.sh --strict
./scripts/sentinel/verify.sh
```

The full FCC local end-to-end lifecycle is separate:

```bash
./scripts/full-setup.sh --test
```

Do not commit `.env`, private keys, RPC credentials, TEE credentials, or other machine-specific values.
EOF

  python3 <<'PY'
from pathlib import Path

readme = Path("README.md")
text = readme.read_text(encoding="utf-8")
entry = "- [Development setup](docs/development-setup.md)\n"
anchor = "- [Architecture](docs/architecture.md)\n"

if entry not in text:
    if anchor not in text:
        raise SystemExit("Could not find the README documentation list anchor.")
    text = text.replace(anchor, entry + anchor, 1)
    readme.write_text(text, encoding="utf-8")
PY

  python3 <<'PY'
from pathlib import Path

workflow = Path(".github/workflows/quality.yml")
text = workflow.read_text(encoding="utf-8")
old = '          go-version: "1.25.1"'
new = '          go-version: "1.25.12"'

if old in text:
    text = text.replace(old, new, 1)
elif new not in text:
    raise SystemExit("Unexpected Go version declaration in quality workflow.")

workflow.write_text(text, encoding="utf-8")
PY

  python3 <<'PY'
from pathlib import Path

verify = Path("scripts/sentinel/verify.sh")
text = verify.read_text(encoding="utf-8")
old = """if command -v shellcheck >/dev/null 2>&1; then
  info "Running ShellCheck on Sentinel-maintained scripts"
  shellcheck scripts/sentinel/*.sh scripts/patches/*.sh
fi
"""
new = """if command -v shellcheck >/dev/null 2>&1; then
  info "Running ShellCheck on maintained Sentinel scripts"
  shellcheck scripts/sentinel/*.sh
fi
"""

if old in text:
    text = text.replace(old, new, 1)
elif new not in text:
    raise SystemExit("Unexpected ShellCheck block in scripts/sentinel/verify.sh.")

verify.write_text(text, encoding="utf-8")
PY

  ok "Prepared tracked development-setup changes."
}

run_checks() {
  cd "$PROJECT_ROOT"
  export PATH="/usr/local/go/bin:$PATH"
  hash -r

  info "Checking patch and maintained shell scripts"
  bash -n "$ARCHIVE_RELATIVE_PATH"
  bash -n scripts/sentinel/check-dev-env.sh
  bash -n scripts/sentinel/verify.sh
  shellcheck scripts/sentinel/*.sh
  git diff --check

  info "Checking the complete local development environment"
  ./scripts/sentinel/check-dev-env.sh --strict

  info "Running the complete non-chain repository verification suite"
  ./scripts/sentinel/verify.sh

  ok "All environment and repository checks passed."
}

commit_and_push() {
  cd "$PROJECT_ROOT"

  git add \
    .github/workflows/quality.yml \
    README.md \
    docs/development-setup.md \
    scripts/sentinel/verify.sh \
    "$ARCHIVE_RELATIVE_PATH"

  git diff --cached --check
  [[ -n "$(git diff --cached --name-only)" ]] ||
    die "No tracked changes were staged."

  git commit -m "$COMMIT_MESSAGE"
  git push origin "$REQUIRED_BRANCH"

  if [[ "$(dirname -- "$SCRIPT_PATH")" == "$PROJECT_ROOT" && "$SCRIPT_PATH" != "$PROJECT_ROOT/$ARCHIVE_RELATIVE_PATH" ]]; then
    rm -f "$SCRIPT_PATH"
  fi

  [[ -z "$(git status --porcelain=v1)" ]] ||
    die "Working tree is not clean after commit and push."

  printf '\n'
  ok "Workstation setup completed and pushed to origin/develop."
  printf 'Go:         %s\n' "$(/usr/local/go/bin/go version)"
  printf 'ShellCheck: %s\n' "$(shellcheck --version | awk '/^version:/{print $2}')"
  printf 'Commit:     %s\n' "$(git rev-parse --short HEAD)"
  printf '\nNext stage: Patch 004 — versioned protocol types and canonical cross-language hashing.\n'
}

main() {
  require_command git
  require_command python3
  require_command sudo
  require_command apt-get
  require_command sha256sum
  require_command tar
  require_command uname
  require_command awk
  require_command sed

  [[ -d "$PROJECT_ROOT/.git" ]] || die "Not a Git repository: $PROJECT_ROOT"

  configure_git_identity
  ensure_safe_repository_state

  TEMP_DIR="$(mktemp -d)"

  install_system_packages
  require_command curl
  require_command jq
  require_command shellcheck

  install_go
  ensure_shell_path
  ensure_local_env

  cd "$PROJECT_ROOT"
  write_repository_changes
  run_checks
  commit_and_push
}

main "$@"
