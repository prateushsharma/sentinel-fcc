#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

readonly PROJECT_NAME="sentinel-fcc"
readonly USER_REPO_HTTPS="https://github.com/prateushsharma/sentinel-fcc.git"
readonly USER_REPO_SLUG="prateushsharma/sentinel-fcc"
readonly UPSTREAM_REPO="https://github.com/flare-foundation/fce-extension-scaffold.git"
readonly PATCH_ARCHIVE_PATH="scripts/patches/001-bootstrap-project.sh"
SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/$(basename -- "${BASH_SOURCE[0]}")"
PROJECT_ROOT="${1:-$(pwd)}"
PROJECT_ROOT="$(mkdir -p "$PROJECT_ROOT" && cd "$PROJECT_ROOT" && pwd)"

TEMP_DIR=""
STAGING_REPO=""

info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

cleanup() {
  if [[ -n "${TEMP_DIR:-}" && -d "$TEMP_DIR" ]]; then
    rm -rf "$TEMP_DIR"
  fi
}
trap cleanup EXIT
trap 'die "Bootstrap failed at line $LINENO while running: $BASH_COMMAND"' ERR

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

configure_git_identity() {
  local repo="$1"
  local git_name git_email

  git_name="$(git -C "$repo" config user.name || true)"
  git_email="$(git -C "$repo" config user.email || true)"

  if [[ -z "$git_name" ]]; then
    read -r -p "Git author name: " git_name
    [[ -n "$git_name" ]] || die "Git author name cannot be empty."
    git -C "$repo" config user.name "$git_name"
  fi

  if [[ -z "$git_email" ]]; then
    read -r -p "Git author email: " git_email
    [[ -n "$git_email" ]] || die "Git author email cannot be empty."
    git -C "$repo" config user.email "$git_email"
  fi

  ok "Git author: $git_name <$git_email>"
}

root_is_safe_for_install() {
  local entry
  shopt -s dotglob nullglob
  local entries=("$PROJECT_ROOT"/*)
  shopt -u dotglob nullglob

  for entry in "${entries[@]}"; do
    [[ "$entry" == "$SCRIPT_PATH" ]] && continue
    [[ "$(basename "$entry")" == ".DS_Store" ]] && continue
    return 1
  done
  return 0
}

remote_is_empty() {
  local refs
  refs="$(git ls-remote "$USER_REPO_HTTPS" 2>/dev/null)" ||
    die "Cannot access $USER_REPO_HTTPS. Check internet access and repository visibility."
  [[ -z "$refs" ]]
}

write_project_files() {
  local repo="$1"
  local upstream_sha
  upstream_sha="$(git -C "$repo" rev-parse HEAD)"

  mkdir -p \
    "$repo/docs/adr" \
    "$repo/docs/upstream" \
    "$repo/scripts/sentinel" \
    "$repo/scripts/patches" \
    "$repo/.github/workflows" \
    "$repo/.github/ISSUE_TEMPLATE"

  cp "$repo/README.md" "$repo/docs/upstream/fce-extension-scaffold-README.md"
  cp "$SCRIPT_PATH" "$repo/$PATCH_ARCHIVE_PATH"
  chmod 0755 "$repo/$PATCH_ARCHIVE_PATH"

  cat > "$repo/README.md" <<'EOF'
# SentinelFCC

**Confidential transaction firewall for autonomous onchain agents using Flare Confidential Compute.**

SentinelFCC treats the AI agent, its tools, retrieved content, relayers, frontends, and TEE host operator as potentially compromised. A transaction executes only when a registered confidential-compute extension has evaluated the exact intent against the account owner's private policy and returned a valid, unexpired, replay-protected authorization.

## Core flow

```text
Agent proposes an intent
        ↓
Client authenticates and encrypts the evaluation request
        ↓
Sentinel extension decodes, simulates, and evaluates it inside a TEE
        ↓
TEE returns an attested allow/deny decision bound to the exact intent
        ↓
Sentinel onchain guard verifies the decision
        ↓
Approved intent executes; rejected or unverifiable intent fails closed
```

## Security invariants

1. No protected account transaction executes without a valid Sentinel authorization.
2. An authorization is valid for one exact transaction, account, chain, policy version, nonce, and time window.
3. A decision cannot be replayed or reused after policy revocation.
4. Failed, stale, unsupported, or ambiguous analysis results in denial.
5. Plaintext policy data and rejected transaction details must not be exposed through logs, proxies, or onchain storage.

## Repository status

The repository is under active development. The current base is Flare Foundation's FCC extension scaffold, retained as the `flare-upstream` Git remote. Production deployment is not recommended until the protocol, contracts, extension, infrastructure, and operational controls have completed independent security review.

## Development

The extension implementation language is Go.

```bash
cp .env.example .env
# Ensure LANGUAGE=go
./scripts/sentinel/check-dev-env.sh
./scripts/sentinel/verify.sh
```

The full local onchain lifecycle additionally requires Flare's local FCC/e2e infrastructure:

```bash
./scripts/full-setup.sh --test
```

## Documentation

- [Architecture](docs/architecture.md)
- [Threat model](docs/threat-model.md)
- [Protocol](docs/protocol.md)
- [Policy schema](docs/policy-schema.md)
- [Decision format](docs/decision-format.md)
- [Trust assumptions](docs/trust-assumptions.md)
- [Failure modes](docs/failure-modes.md)
- [Deployment security](docs/deployment-security.md)
- [Upstream integration](docs/upstream.md)
- [Contributing](CONTRIBUTING.md)
- [Security policy](SECURITY.md)

## License

No project license has been selected yet. Flare scaffold components retain their original notices and licensing terms.
EOF

  cat > "$repo/docs/architecture.md" <<'EOF'
# Architecture

## Components

### Sentinel client SDK

The client SDK canonicalizes transaction intents, authenticates requests, encrypts confidential inputs for the selected TEE deployment, submits evaluations, and verifies returned metadata before forwarding an authorization to the onchain guard.

### Confidential extension

The extension performs:

1. request authentication and replay checks;
2. policy retrieval and commitment validation;
3. calldata and nested-call decoding;
4. transaction simulation and effect normalization;
5. deterministic policy evaluation;
6. risk-flag and decision generation;
7. attested result construction.

The extension must not use an LLM to decide whether a transaction is approved. An LLM may produce a non-authoritative explanation after the deterministic decision has been created.

### Onchain policy registry

The registry stores policy commitments, policy versions, authorized agents, revocation state, and accepted verifier/code versions. It does not store plaintext policies.

### Onchain verifier and executor

The verifier authenticates the FCC result and decodes the versioned decision. The executor checks exact-intent binding, account and chain scope, policy state, nonce consumption, time bounds, and emergency controls before executing the call.

### Simulation providers

Simulation is accessed through a provider-neutral interface. The production target is a quorum of independent providers. Provider disagreement, stale state, unsupported traces, or incomplete effects fail closed.

## Data classification

| Data | Classification | Intended location |
|---|---|---|
| Plaintext policy | Confidential | TEE only |
| Proposed rejected intent | Confidential | Client and TEE only |
| Approved transaction calldata | Public after execution | Blockchain |
| Policy commitment | Public | Registry |
| Decision metadata | Public/minimized | Verifier and executor |
| Detailed simulation trace | Confidential | TEE only |
| Coarse risk flags | Configurable/public | Decision |

## Upgrade model

Protocol messages are explicitly versioned. Policy schemas, decision schemas, decoders, and accepted TEE code versions evolve through controlled migration. The executor must never reinterpret an old signed payload under a new schema.
EOF

  cat > "$repo/docs/threat-model.md" <<'EOF'
# Threat Model

## Protected assets

- Funds and permissions controlled by protected accounts.
- Private account policies, allowlists, limits, and strategy metadata.
- Unpublished transaction intents and rejected malicious payloads.
- TEE signing and decryption authority.
- Policy and agent authorization state.

## Adversaries

- Compromised or prompt-injected AI agent.
- Malicious MCP server, API, website, document, or peer agent.
- Malicious frontend, relayer, public proxy, or network observer.
- RPC provider returning stale or manipulated simulation data.
- TEE host operator attempting to inspect or alter processing.
- Contract caller attempting substitution, replay, or cross-chain reuse.
- Compromised administrator or governance signer.

## Required invariants

1. Only an authenticated, authorized agent can request evaluation for an account.
2. The evaluated intent and executed intent are byte-for-byte equivalent under the canonical encoding.
3. Every decision is scoped to the protocol version, chain, executor, account, agent, policy version, nonce, and validity window.
4. Revoked or superseded policies cannot authorize new execution.
5. Every authorization is single-use.
6. Unknown, malformed, stale, inconsistent, or failed analysis denies execution.
7. Sensitive values are excluded from application logs, metrics, traces, and error responses.
8. Administrative changes are explicit, auditable, and recoverable through a documented process.

## Out of scope for the first audited release

- Protection against all hardware side channels.
- Privacy of calldata after an approved public-chain transaction executes.
- Correctness of external protocols called by an approved transaction.
- Recovery of funds already transferred before Sentinel protection was enabled.
EOF

  cat > "$repo/docs/protocol.md" <<'EOF'
# Protocol

## Message families

The protocol will define independently versioned messages for:

- policy registration and update;
- policy revocation;
- agent authorization and revocation;
- transaction evaluation;
- firewall decision;
- execution receipt.

## Canonical encoding

Every signed or committed object must have one normative encoding shared by Go, Solidity, and TypeScript. Golden vectors must cover valid encodings and mutation cases. JSON is an API representation, not the signature preimage.

## Evaluation lifecycle

1. The owner registers a policy commitment and active policy version.
2. An authorized agent creates a transaction intent.
3. The client creates a request ID and signs the canonical evaluation request.
4. Confidential fields are encrypted to an attested TEE recipient.
5. The extension authenticates the request and verifies policy state.
6. The extension decodes and simulates the exact intent.
7. The deterministic engine creates an allow/deny decision.
8. The TEE returns an attested result bound to the canonical decision.
9. The executor validates the result and consumes the nonce.
10. The exact approved transaction executes atomically or reverts.

## Failure semantics

The default action is deny. No exception, timeout, unsupported decoder, unavailable provider, or malformed response may be converted into approval.
EOF

  cat > "$repo/docs/policy-schema.md" <<'EOF'
# Policy Schema

Policies are private, owner-authenticated, versioned objects. Their public representation is a commitment and lifecycle metadata.

## Planned rule groups

- chain and account scope;
- authorized agents and request limits;
- target address and runtime bytecode rules;
- function-selector and operation rules;
- native, fungible-token, and NFT transfer limits;
- approval and permit restrictions;
- recipient and spender controls;
- protocol-specific constraints;
- rolling spend budgets;
- simulation freshness and provider quorum;
- default action and emergency restrictions.

## Compatibility rules

- `schemaVersion` selects the parser.
- `policyVersion` is monotonic per protected account.
- Unknown required fields cause rejection.
- Older versions remain valid only during an explicit migration window.
- A policy update invalidates authorizations tied to prior versions unless the registry explicitly permits a grace period.
EOF

  cat > "$repo/docs/decision-format.md" <<'EOF'
# Decision Format

A firewall decision must bind at least:

- protocol and decision schema versions;
- request ID and canonical intent hash;
- policy commitment and policy version;
- chain ID, executor, protected account, and authorized agent;
- target, value, and calldata hash;
- nonce and validity window;
- simulation block number/hash and normalized simulation commitment;
- approval boolean, risk score, and machine-readable risk flags.

## Replay resistance

The executor consumes the nonce or decision ID before external execution. A reverted external call must not accidentally make the authorization reusable unless the protocol explicitly defines safe retry semantics.

## Domain separation

The signed preimage must include an unambiguous Sentinel domain, chain ID, and verifying contract. No generic message signature is accepted.
EOF

  cat > "$repo/docs/trust-assumptions.md" <<'EOF'
# Trust Assumptions

## Trusted

- The attested confidential-compute hardware and firmware satisfy their documented security properties.
- The registered Sentinel code measurement corresponds to reviewed source and build inputs.
- The deterministic policy engine and canonical encoders are correctly implemented.
- The accepted onchain verifier and registry enforce the documented protocol.

## Minimized or untrusted

- AI agents and language models.
- MCP servers and other tools.
- Frontends and relayers.
- Public extension proxies.
- TEE host operators.
- Individual RPC providers.
- Transaction submitters.

## Residual trust

Confidential computing reduces host trust but does not eliminate hardware, firmware, supply-chain, side-channel, governance, or implementation risk. Production deployment requires code reproducibility, attestation verification, key rotation, independent review, and incident response.
EOF

  cat > "$repo/docs/failure-modes.md" <<'EOF'
# Failure Modes

| Failure | Required behaviour |
|---|---|
| TEE or proxy unavailable | Deny; never bypass |
| Request signature invalid | Deny and emit minimal audit metadata |
| Policy missing, stale, or revoked | Deny |
| Unsupported or malformed calldata | Deny |
| Nested call cannot be fully decoded | Deny unless an explicit reviewed rule permits it |
| Simulation reverts | Deny |
| Simulation providers disagree | Deny |
| Simulation block too old | Deny |
| Attestation or result signature invalid | Onchain rejection |
| Decision expired | Onchain rejection |
| Nonce already consumed | Onchain rejection |
| Intent differs from decision | Onchain rejection |
| Accepted code version revoked | Onchain rejection |
| Administrative compromise suspected | Pause protected execution and begin rotation procedure |

Error responses must not include plaintext policy values, decrypted calldata, secrets, provider credentials, or detailed confidential traces.
EOF

  cat > "$repo/docs/deployment-security.md" <<'EOF'
# Deployment Security

Production deployment requires:

- reproducible, pinned extension images;
- minimal runtime images without interactive tooling;
- verified TEE measurements and accepted code-version governance;
- separate development, staging, and production keys;
- threshold-controlled administrative actions;
- explicit key-generation, backup, rotation, and revocation procedures;
- multiple TEE deployments and health monitoring;
- multiple independent simulation providers;
- rate limiting, authenticated requests, and idempotency;
- secret-free structured logs and privacy-reviewed telemetry;
- dependency, container, contract, and infrastructure scanning;
- Foundry unit, fuzz, invariant, fork, and integration tests;
- independent smart-contract and confidential-extension review;
- documented incident response and recovery drills.

The first public deployment remains a testnet system until Flare FCC and SentinelFCC are both suitable for production use.
EOF

  cat > "$repo/docs/upstream.md" <<EOF
# Upstream Integration

SentinelFCC is based on:

- Repository: \`$UPSTREAM_REPO\`
- Bootstrap commit: \`$upstream_sha\`
- Read-only remote: \`flare-upstream\`

The push URL for \`flare-upstream\` is intentionally disabled to reduce accidental pushes.

## Sync procedure

\`\`\`bash
git switch main
git fetch flare-upstream
git merge --ff-only flare-upstream/main
git push origin main

git switch develop
git merge main
git push origin develop
\`\`\`

When upstream changes conflict with Sentinel protocol code, resolve them on a dedicated maintenance branch and run the complete verification suite before merging.
EOF

  cat > "$repo/docs/adr/0001-use-go-for-confidential-extension.md" <<'EOF'
# ADR-0001: Use Go for the confidential extension

- Status: Accepted
- Date: 2026-07-30

## Context

The Flare FCC scaffold supports Go, Python, and TypeScript. Sentinel's extension will contain security-sensitive parsers, canonical encoders, simulation adapters, policy evaluation, and concurrency-controlled state.

## Decision

Use Go for the confidential extension and Flare deployment tooling integration.

## Reasons

- The upstream Go image is the smallest and strongest reproducibility path.
- Static typing and explicit error handling suit security-sensitive protocol code.
- A static binary and minimal runtime reduce image size and attack surface.
- The upstream scaffold and deployment tooling already use Go extensively.

## Consequences

The web client and SDK may use TypeScript, but normative protocol vectors must prove cross-language encoding compatibility.
EOF

  cat > "$repo/SECURITY.md" <<'EOF'
# Security Policy

SentinelFCC is experimental security infrastructure and must not be used to custody production funds at this stage.

## Reporting a vulnerability

Do not open a public issue containing exploit details, private keys, confidential policies, or vulnerable deployment information.

Until a dedicated private disclosure channel is published, contact the repository owner through their verified GitHub profile and request a private reporting channel. Include only a minimal non-sensitive summary in the initial contact.

## Supported versions

Only the latest commit on `main` is considered for security fixes. Development branches may contain incomplete or unsafe functionality.

## Secrets

Never commit wallet keys, TEE keys, RPC credentials, database credentials, `.env` files, policy plaintext, decrypted requests, or production addresses with sensitive operational meaning.
EOF

  cat > "$repo/CONTRIBUTING.md" <<'EOF'
# Contributing

## Branches

- `main`: reviewed, releasable repository state.
- `develop`: integration branch.
- `feat/*`, `fix/*`, `docs/*`, `chore/*`, `security/*`: short-lived work branches.

## Commit style

Use Conventional Commits, for example:

```text
feat(protocol): add canonical intent hashing
fix(executor): consume decision nonce before external call
test(policy): cover nested unlimited approvals
docs(threat-model): define RPC disagreement handling
```

## Required checks

```bash
./scripts/sentinel/check-dev-env.sh
./scripts/sentinel/verify.sh
```

Changes affecting signed data must include updated golden vectors and cross-language compatibility tests. Security-relevant changes must update the threat model or explain why no documentation change is required.
EOF

  cat > "$repo/.editorconfig" <<'EOF'
root = true

[*]
charset = utf-8
end_of_line = lf
insert_final_newline = true
trim_trailing_whitespace = true

[*.{go,sol,ts,tsx,js,json,yml,yaml,md,sh,toml}]
indent_style = space
indent_size = 2

[*.go]
indent_style = tab

[Makefile]
indent_style = tab
EOF

  cat > "$repo/.gitattributes" <<'EOF'
* text=auto eol=lf
*.sh text eol=lf
*.go text eol=lf
*.sol text eol=lf
*.md text eol=lf
*.png binary
*.jpg binary
*.jpeg binary
*.webp binary
EOF

  cat > "$repo/.github/CODEOWNERS" <<'EOF'
* @prateushsharma
/contracts/ @prateushsharma
/go/ @prateushsharma
/docs/ @prateushsharma
EOF

  cat > "$repo/.github/PULL_REQUEST_TEMPLATE.md" <<'EOF'
## Summary

## Security impact

- [ ] No security-sensitive behaviour changed.
- [ ] Threat model or trust assumptions updated.
- [ ] Signed/canonical data format changed and golden vectors updated.
- [ ] Failure behaviour remains fail-closed.

## Verification

- [ ] `./scripts/sentinel/verify.sh`
- [ ] New or updated tests cover the change.
- [ ] No secrets or confidential payloads are present.
EOF

  cat > "$repo/.github/ISSUE_TEMPLATE/bug_report.yml" <<'EOF'
name: Bug report
description: Report a reproducible non-sensitive defect
title: "bug: "
labels: ["bug"]
body:
  - type: markdown
    attributes:
      value: |
        Do not submit vulnerabilities, secrets, private policies, or exploit details here. Follow SECURITY.md.
  - type: textarea
    id: description
    attributes:
      label: Description
      description: What happened and what did you expect?
    validations:
      required: true
  - type: textarea
    id: reproduction
    attributes:
      label: Reproduction
      description: Provide minimal steps without sensitive data.
    validations:
      required: true
  - type: input
    id: commit
    attributes:
      label: Commit
      description: Git commit SHA where the issue occurs.
    validations:
      required: true
  - type: textarea
    id: environment
    attributes:
      label: Environment
      description: OS, Go, Foundry, Docker, and relevant testnet/local configuration.
EOF

  cat > "$repo/.github/dependabot.yml" <<'EOF'
version: 2
updates:
  - package-ecosystem: gomod
    directory: /go
    schedule:
      interval: weekly
    open-pull-requests-limit: 5
  - package-ecosystem: gomod
    directory: /tools
    schedule:
      interval: weekly
    open-pull-requests-limit: 5
  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: weekly
    open-pull-requests-limit: 5
EOF

  cat > "$repo/.github/workflows/quality.yml" <<'EOF'
name: Quality

on:
  push:
    branches: [main, develop]
  pull_request:
    branches: [main, develop]

permissions:
  contents: read

concurrency:
  group: quality-${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  verify:
    runs-on: ubuntu-latest
    timeout-minutes: 30

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Set up Go
        uses: actions/setup-go@v5
        with:
          go-version: "1.25.1"
          cache-dependency-path: |
            go/go.sum
            tools/go.sum

      - name: Set up Foundry
        uses: foundry-rs/foundry-toolchain@v1
        with:
          version: stable

      - name: Install system tools
        run: sudo apt-get update && sudo apt-get install -y jq shellcheck

      - name: Configure extension language
        run: |
          cp .env.example .env
          if grep -q '^LANGUAGE=' .env; then
            sed -i 's/^LANGUAGE=.*/LANGUAGE=go/' .env
          else
            printf '\nLANGUAGE=go\n' >> .env
          fi

      - name: Verify
        run: ./scripts/sentinel/verify.sh --ci
EOF

  cat > "$repo/scripts/sentinel/check-dev-env.sh" <<'EOF'
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
EOF
  chmod 0755 "$repo/scripts/sentinel/check-dev-env.sh"

  cat > "$repo/scripts/sentinel/verify.sh" <<'EOF'
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
  info "Running ShellCheck on Sentinel-maintained scripts"
  shellcheck scripts/sentinel/*.sh scripts/patches/*.sh
fi

info "Checking pinned dependency versions"
./scripts/check-versions.sh

info "Checking Solidity formatting"
forge fmt --check

info "Building Solidity contracts"
forge build

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
EOF
  chmod 0755 "$repo/scripts/sentinel/verify.sh"

  cat > "$repo/Makefile" <<'EOF'
.PHONY: env fmt test verify local-e2e

env:
	./scripts/sentinel/check-dev-env.sh --strict

fmt:
	gofmt -w $$(find go tools -type f -name '*.go')
	forge fmt

test:
	./scripts/test-unit.sh
	./scripts/test-conformance.sh
	cd tools && go test ./...

verify:
	./scripts/sentinel/verify.sh

local-e2e:
	./scripts/full-setup.sh --test
EOF

  # Configure a non-secret local environment file.
  if [[ ! -f "$repo/.env" ]]; then
    cp "$repo/.env.example" "$repo/.env"
  fi
  if grep -q '^LANGUAGE=' "$repo/.env"; then
    sed -i 's/^LANGUAGE=.*/LANGUAGE=go/' "$repo/.env"
  else
    printf '\nLANGUAGE=go\n' >> "$repo/.env"
  fi
}

run_bootstrap_checks() {
  local repo="$1"

  info "Running deterministic bootstrap checks"
  git -C "$repo" diff --check

  while IFS= read -r -d '' script; do
    bash -n "$script"
  done < <(find "$repo/scripts" -type f -name '*.sh' -print0)

  if command -v shellcheck >/dev/null 2>&1; then
    shellcheck \
      "$repo/scripts/sentinel/check-dev-env.sh" \
      "$repo/scripts/sentinel/verify.sh" \
      "$repo/$PATCH_ARCHIVE_PATH"
  else
    warn "shellcheck is unavailable; CI will enforce it."
  fi

  if "$repo/scripts/sentinel/check-dev-env.sh" --strict >/dev/null 2>&1; then
    info "All local prerequisites found; running the full non-chain verification suite"
    (
      cd "$repo"
      ./scripts/sentinel/verify.sh
    )
  else
    warn "Some FCC prerequisites are missing, so heavy local checks were skipped."
    warn "The pushed GitHub Actions workflow will run the complete non-chain verification suite."
    "$repo/scripts/sentinel/check-dev-env.sh" || true
  fi
}

configure_github_metadata() {
  if ! command -v gh >/dev/null 2>&1; then
    warn "GitHub CLI is not installed; repository metadata was not updated automatically."
    return
  fi

  if ! gh auth status >/dev/null 2>&1; then
    warn "GitHub CLI is not authenticated; repository metadata was not updated automatically."
    return
  fi

  gh repo edit "$USER_REPO_SLUG" \
    --description "Confidential transaction firewall for autonomous onchain agents using Flare Confidential Compute" \
    --add-topic "confidential-computing" \
    --add-topic "tee" \
    --add-topic "flare" \
    --add-topic "ai-agents" \
    --add-topic "smart-contract-security" >/dev/null

  ok "Updated GitHub repository description and topics."
}

push_branches() {
  local repo="$1"

  (
    cd "$repo"

    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
      gh auth setup-git >/dev/null 2>&1 || true
    fi

    info "Pushing main to origin"
    if ! git push -u origin main; then
      warn "Push authentication failed. The local repository is complete."
      warn "Authenticate with GitHub, then run:"
      warn "  cd \"$repo\""
      warn "  git push -u origin main"
      warn "  git switch develop"
      warn "  git push -u origin develop"
      return 2
    fi

    if git show-ref --verify --quiet refs/heads/develop; then
      git switch develop
    else
      git switch -c develop
    fi

    info "Pushing develop to origin"
    if ! git push -u origin develop; then
      warn "main was pushed, but develop could not be pushed."
      warn "Authenticate with GitHub and run: git push -u origin develop"
      return 3
    fi
  )
}

resume_existing_repository() {
  info "Existing SentinelFCC repository detected; validating and resuming push."

  [[ -d "$PROJECT_ROOT/.git" ]] || die "Expected a Git repository at $PROJECT_ROOT."
  [[ "$(git -C "$PROJECT_ROOT" remote get-url origin 2>/dev/null || true)" == "$USER_REPO_HTTPS" ]] ||
    die "The existing origin does not match $USER_REPO_HTTPS."

  configure_git_identity "$PROJECT_ROOT"

  if [[ -f "$SCRIPT_PATH" && "$SCRIPT_PATH" != "$PROJECT_ROOT/$PATCH_ARCHIVE_PATH" ]]; then
    mkdir -p "$PROJECT_ROOT/scripts/patches"
    cp "$SCRIPT_PATH" "$PROJECT_ROOT/$PATCH_ARCHIVE_PATH"
    chmod 0755 "$PROJECT_ROOT/$PATCH_ARCHIVE_PATH"
    rm -f "$SCRIPT_PATH"
  fi

  (
    cd "$PROJECT_ROOT"
    git diff --check
    if [[ -n "$(git status --porcelain)" ]]; then
      warn "The repository contains uncommitted changes. They will not be committed automatically."
      git status --short
      die "Commit or discard these changes before resuming the bootstrap."
    fi
  )

  push_branches "$PROJECT_ROOT"
  configure_github_metadata
  ok "SentinelFCC bootstrap is complete."
}

main() {
  require_command git
  require_command sort
  require_command find
  require_command sed
  require_command awk

  if [[ -d "$PROJECT_ROOT/.git" ]]; then
    resume_existing_repository
    return
  fi

  root_is_safe_for_install ||
    die "Project root is not empty: $PROJECT_ROOT. Use a new empty directory."

  remote_is_empty ||
    die "The GitHub repository is not empty. This bootstrap intentionally refuses to overwrite it."

  TEMP_DIR="$(mktemp -d)"
  STAGING_REPO="$TEMP_DIR/$PROJECT_NAME"

  info "Cloning the official Flare FCC scaffold with full history"
  git clone --origin flare-upstream "$UPSTREAM_REPO" "$STAGING_REPO"

  git -C "$STAGING_REPO" branch -M main
  git -C "$STAGING_REPO" remote set-url --push flare-upstream DISABLED
  git -C "$STAGING_REPO" remote add origin "$USER_REPO_HTTPS"

  configure_git_identity "$STAGING_REPO"
  write_project_files "$STAGING_REPO"
  run_bootstrap_checks "$STAGING_REPO"

  (
    cd "$STAGING_REPO"
    git add \
      README.md \
      CONTRIBUTING.md \
      SECURITY.md \
      Makefile \
      .editorconfig \
      .gitattributes \
      .github \
      docs \
      scripts/sentinel \
      "$PATCH_ARCHIVE_PATH"

    git commit -m "chore: bootstrap SentinelFCC project foundation"
    git branch develop
  )

  info "Installing the prepared repository into $PROJECT_ROOT"
  rm -f "$SCRIPT_PATH"
  cp -a "$STAGING_REPO/." "$PROJECT_ROOT/"

  push_status=0
  push_branches "$PROJECT_ROOT" || push_status=$?
  configure_github_metadata

  printf '\n'
  ok "Repository created at: $PROJECT_ROOT"
  ok "Upstream remote: flare-upstream (push disabled)"
  ok "Development branch: develop"
  info "Current branch: $(git -C "$PROJECT_ROOT" branch --show-current)"
  info "Upstream commit: $(git -C "$PROJECT_ROOT" rev-parse flare-upstream/main)"
  info "Foundation commit: $(git -C "$PROJECT_ROOT" rev-parse main)"

  if (( push_status != 0 )); then
    exit "$push_status"
  fi

  printf '\nNext command:\n  cd %q\n  ./scripts/sentinel/check-dev-env.sh\n' "$PROJECT_ROOT"
}

main "$@"
