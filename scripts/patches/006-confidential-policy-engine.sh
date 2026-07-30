#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

readonly EXPECTED_ORIGIN_SLUG="prateushsharma/sentinel-fcc"
readonly PRIMARY_BASE_BRANCH="feat/onchain-policy-executor"
readonly FALLBACK_BASE_BRANCH="develop"
readonly FEATURE_BRANCH="feat/confidential-policy-engine"
readonly ARCHIVE_RELATIVE_PATH="scripts/patches/006-confidential-policy-engine.sh"

SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/$(basename -- "${BASH_SOURCE[0]}")"
SCRIPT_BASENAME="$(basename -- "$SCRIPT_PATH")"
PROJECT_ROOT="${1:-$(pwd)}"
PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd)"
BASE_BRANCH=""

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

validate_and_create_branch() {
  local current_branch origin_url origin_slug status_line current_sha remote_sha

  [[ -d "$PROJECT_ROOT/.git" ]] || die "Not a Git repository: $PROJECT_ROOT"

  current_branch="$(git -C "$PROJECT_ROOT" branch --show-current)"
  case "$current_branch" in
    "$PRIMARY_BASE_BRANCH"|"$FALLBACK_BASE_BRANCH")
      BASE_BRANCH="$current_branch"
      ;;
    *)
      die "Run Patch 006 from '$PRIMARY_BASE_BRANCH' or '$FALLBACK_BASE_BRANCH'; current branch is '$current_branch'."
      ;;
  esac

  origin_url="$(git -C "$PROJECT_ROOT" remote get-url origin 2>/dev/null || true)"
  origin_slug="$(normalize_github_slug "$origin_url")"
  [[ "$origin_slug" == "$EXPECTED_ORIGIN_SLUG" ]] ||
    die "Unexpected origin remote: $origin_url"

  git -C "$PROJECT_ROOT" fetch origin "$BASE_BRANCH" --prune
  current_sha="$(git -C "$PROJECT_ROOT" rev-parse HEAD)"
  remote_sha="$(git -C "$PROJECT_ROOT" rev-parse "origin/$BASE_BRANCH")"
  [[ "$current_sha" == "$remote_sha" ]] ||
    die "Local $BASE_BRANCH is not synchronized with origin/$BASE_BRANCH."

  while IFS= read -r status_line; do
    [[ -z "$status_line" ]] && continue
    if [[ "$(dirname -- "$SCRIPT_PATH")" == "$PROJECT_ROOT" && "$status_line" == "?? $SCRIPT_BASENAME" ]]; then
      continue
    fi
    printf '%s\n' "$status_line" >&2
    die "Working tree contains unrelated changes."
  done < <(git -C "$PROJECT_ROOT" status --porcelain=v1 --untracked-files=all)

  for required in \
    contracts/SentinelExecutor.sol \
    contracts/SentinelPolicyRegistry.sol \
    contracts/libraries/SentinelProtocol.sol \
    go/pkg/protocol/hashing.go \
    go/internal/extension/extension.go \
    go/internal/config/config.go \
    contracts/InstructionSender.sol; do
    [[ -f "$PROJECT_ROOT/$required" ]] ||
      die "Required prior-stage file is missing: $required"
  done

  if git -C "$PROJECT_ROOT" show-ref --verify --quiet "refs/heads/$FEATURE_BRANCH"; then
    die "Local branch already exists: $FEATURE_BRANCH"
  fi
  if git -C "$PROJECT_ROOT" ls-remote --exit-code --heads origin "$FEATURE_BRANCH" >/dev/null 2>&1; then
    die "Remote branch already exists: $FEATURE_BRANCH"
  fi

  git -C "$PROJECT_ROOT" switch -c "$FEATURE_BRANCH"
  ok "Created feature branch: $FEATURE_BRANCH"
  info "Pull-request base will be: $BASE_BRANCH"
}

write_policy_package() {
  mkdir -p "$PROJECT_ROOT/go/pkg/policy"

  cat > "$PROJECT_ROOT/go/pkg/policy/doc.go" <<'EOF'
// Package policy defines SentinelFCC's private, TEE-resident policy schema.
//
// Policy contents are normalized before hashing. Only the resulting rules and
// chain-scope commitments are intended to be published onchain.
package policy
EOF

  cat > "$PROJECT_ROOT/go/pkg/policy/types.go" <<'EOF'
package policy

import (
	"github.com/ethereum/go-ethereum/common"
)

const (
	// CurrentSchemaVersion is the private policy schema supported by this engine.
	CurrentSchemaVersion uint16 = 1

	// MaximumRiskScore is the inclusive upper bound for policy risk thresholds.
	MaximumRiskScore uint8 = 100
)

// PrivatePolicy contains confidential rules evaluated inside the TEE.
//
// Uint256 values are canonical base-10 strings. This avoids JSON precision loss
// and makes the normalized representation portable across languages.
type PrivatePolicy struct {
	SchemaVersion               uint16           `json:"schemaVersion"`
	PolicyID                    common.Hash      `json:"policyId"`
	Owner                       common.Address   `json:"owner"`
	Account                     common.Address   `json:"account"`
	Version                     uint64           `json:"version"`
	ValidAfter                  uint64           `json:"validAfter"`
	ValidUntil                  uint64           `json:"validUntil"`
	AllowedChainIDs             []string         `json:"allowedChainIds"`
	AuthorizedAgents            []common.Address `json:"authorizedAgents"`
	MaxNativeValue              string           `json:"maxNativeValue"`
	MaxRiskScore                uint8            `json:"maxRiskScore"`
	MaxSimulationBlockAge       uint64           `json:"maxSimulationBlockAge"`
	RequireSuccessfulSimulation bool             `json:"requireSuccessfulSimulation"`
	RequireProviderAgreement    bool             `json:"requireProviderAgreement"`
	Targets                     []TargetRule      `json:"targets"`
}

// TargetRule contains rules for one exact destination contract.
type TargetRule struct {
	Target                 common.Address   `json:"target"`
	CodeHash               common.Hash      `json:"codeHash"`
	AllowAnySelector       bool             `json:"allowAnySelector"`
	Selectors              []string         `json:"selectors"`
	MaxNativeValue         string           `json:"maxNativeValue"`
	MaxERC20Transfer       string           `json:"maxErc20Transfer"`
	MaxERC20Approval       string           `json:"maxErc20Approval"`
	AllowUnlimitedApproval bool             `json:"allowUnlimitedApproval"`
	AllowedRecipients      []common.Address `json:"allowedRecipients"`
}
EOF

  cat > "$PROJECT_ROOT/go/pkg/policy/uint256.go" <<'EOF'
package policy

import (
	"errors"
	"fmt"
	"math/big"
)

var ErrInvalidUint256 = errors.New("invalid canonical uint256")

// ParseUint256 parses a canonical base-10 uint256 string.
func ParseUint256(value string) (*big.Int, error) {
	if value == "" {
		return nil, fmt.Errorf("%w: empty string", ErrInvalidUint256)
	}
	if len(value) > 1 && value[0] == '0' {
		return nil, fmt.Errorf("%w: leading zero", ErrInvalidUint256)
	}

	for _, char := range value {
		if char < '0' || char > '9' {
			return nil, fmt.Errorf("%w: non-decimal character", ErrInvalidUint256)
		}
	}

	parsed, ok := new(big.Int).SetString(value, 10)
	if !ok || parsed.Sign() < 0 || parsed.BitLen() > 256 {
		return nil, ErrInvalidUint256
	}
	return parsed, nil
}
EOF

  cat > "$PROJECT_ROOT/go/pkg/policy/normalize.go" <<'EOF'
package policy

import (
	"bytes"
	"encoding/hex"
	"errors"
	"fmt"
	"math/big"
	"sort"
	"strings"

	"github.com/ethereum/go-ethereum/common"
)

var (
	ErrDuplicateValue     = errors.New("duplicate policy value")
	ErrInvalidSelector    = errors.New("invalid selector")
	ErrInvalidPolicy      = errors.New("invalid private policy")
	ErrInvalidPolicyChain = errors.New("invalid policy chain")
)

func normalizeDecimal(value string) (string, *big.Int, error) {
	parsed, err := ParseUint256(value)
	if err != nil {
		return "", nil, err
	}
	return parsed.String(), parsed, nil
}

func normalizeSelector(value string) (string, error) {
	if len(value) != 10 || !strings.HasPrefix(value, "0x") {
		return "", ErrInvalidSelector
	}

	decoded, err := hex.DecodeString(value[2:])
	if err != nil || len(decoded) != 4 {
		return "", ErrInvalidSelector
	}
	return "0x" + hex.EncodeToString(decoded), nil
}

func sortAddresses(values []common.Address) {
	sort.Slice(values, func(i, j int) bool {
		return bytes.Compare(values[i][:], values[j][:]) < 0
	})
}

func sortHashes(values []common.Hash) {
	sort.Slice(values, func(i, j int) bool {
		return bytes.Compare(values[i][:], values[j][:]) < 0
	})
}

func ensureUniqueAddresses(name string, values []common.Address) error {
	for index, value := range values {
		if value == (common.Address{}) {
			return fmt.Errorf("%s[%d]: zero address: %w", name, index, ErrInvalidPolicy)
		}
		if index > 0 && value == values[index-1] {
			return fmt.Errorf("%s: %w", name, ErrDuplicateValue)
		}
	}
	return nil
}

func normalizeChainIDs(values []string) ([]string, error) {
	type chainValue struct {
		text  string
		value *big.Int
	}

	chains := make([]chainValue, 0, len(values))
	for index, raw := range values {
		canonical, parsed, err := normalizeDecimal(raw)
		if err != nil || parsed.Sign() == 0 {
			return nil, fmt.Errorf("allowedChainIds[%d]: %w", index, ErrInvalidPolicyChain)
		}
		chains = append(chains, chainValue{text: canonical, value: parsed})
	}

	sort.Slice(chains, func(i, j int) bool {
		return chains[i].value.Cmp(chains[j].value) < 0
	})

	normalized := make([]string, len(chains))
	for index, chain := range chains {
		if index > 0 && chain.value.Cmp(chains[index-1].value) == 0 {
			return nil, fmt.Errorf("allowedChainIds: %w", ErrDuplicateValue)
		}
		normalized[index] = chain.text
	}
	return normalized, nil
}

func normalizeTarget(rule TargetRule, globalMax *big.Int) (TargetRule, error) {
	if rule.Target == (common.Address{}) {
		return TargetRule{}, fmt.Errorf("target: %w", ErrInvalidPolicy)
	}

	maxNative, parsedNative, err := normalizeDecimal(rule.MaxNativeValue)
	if err != nil {
		return TargetRule{}, fmt.Errorf("target %s maxNativeValue: %w", rule.Target.Hex(), err)
	}
	if parsedNative.Cmp(globalMax) > 0 {
		return TargetRule{}, fmt.Errorf(
			"target %s maxNativeValue exceeds global maximum: %w",
			rule.Target.Hex(),
			ErrInvalidPolicy,
		)
	}

	maxTransfer, _, err := normalizeDecimal(rule.MaxERC20Transfer)
	if err != nil {
		return TargetRule{}, fmt.Errorf("target %s maxErc20Transfer: %w", rule.Target.Hex(), err)
	}

	maxApproval, _, err := normalizeDecimal(rule.MaxERC20Approval)
	if err != nil {
		return TargetRule{}, fmt.Errorf("target %s maxErc20Approval: %w", rule.Target.Hex(), err)
	}

	selectors := append([]string(nil), rule.Selectors...)
	for index, selector := range selectors {
		normalized, err := normalizeSelector(selector)
		if err != nil {
			return TargetRule{}, fmt.Errorf(
				"target %s selectors[%d]: %w",
				rule.Target.Hex(),
				index,
				err,
			)
		}
		selectors[index] = normalized
	}
	sort.Strings(selectors)
	for index := 1; index < len(selectors); index++ {
		if selectors[index] == selectors[index-1] {
			return TargetRule{}, fmt.Errorf(
				"target %s selectors: %w",
				rule.Target.Hex(),
				ErrDuplicateValue,
			)
		}
	}
	if !rule.AllowAnySelector && len(selectors) == 0 {
		return TargetRule{}, fmt.Errorf(
			"target %s has no allowed selectors: %w",
			rule.Target.Hex(),
			ErrInvalidPolicy,
		)
	}

	recipients := append([]common.Address(nil), rule.AllowedRecipients...)
	sortAddresses(recipients)
	if err := ensureUniqueAddresses("allowedRecipients", recipients); err != nil {
		return TargetRule{}, fmt.Errorf("target %s: %w", rule.Target.Hex(), err)
	}

	return TargetRule{
		Target:                 rule.Target,
		CodeHash:               rule.CodeHash,
		AllowAnySelector:       rule.AllowAnySelector,
		Selectors:              selectors,
		MaxNativeValue:         maxNative,
		MaxERC20Transfer:       maxTransfer,
		MaxERC20Approval:       maxApproval,
		AllowUnlimitedApproval: rule.AllowUnlimitedApproval,
		AllowedRecipients:      recipients,
	}, nil
}

// Normalize validates a policy and returns a deeply copied canonical form.
func Normalize(input PrivatePolicy) (PrivatePolicy, error) {
	if input.SchemaVersion != CurrentSchemaVersion {
		return PrivatePolicy{}, fmt.Errorf("schemaVersion: %w", ErrInvalidPolicy)
	}
	if input.PolicyID == (common.Hash{}) {
		return PrivatePolicy{}, fmt.Errorf("policyId: %w", ErrInvalidPolicy)
	}
	if input.Owner == (common.Address{}) {
		return PrivatePolicy{}, fmt.Errorf("owner: %w", ErrInvalidPolicy)
	}
	if input.Account == (common.Address{}) {
		return PrivatePolicy{}, fmt.Errorf("account: %w", ErrInvalidPolicy)
	}
	if input.Version == 0 {
		return PrivatePolicy{}, fmt.Errorf("version: %w", ErrInvalidPolicy)
	}
	if input.ValidUntil == 0 || input.ValidAfter > input.ValidUntil {
		return PrivatePolicy{}, fmt.Errorf("validity window: %w", ErrInvalidPolicy)
	}
	if input.MaxRiskScore > MaximumRiskScore {
		return PrivatePolicy{}, fmt.Errorf("maxRiskScore: %w", ErrInvalidPolicy)
	}
	if input.MaxSimulationBlockAge == 0 || input.MaxSimulationBlockAge > 255 {
		return PrivatePolicy{}, fmt.Errorf("maxSimulationBlockAge: %w", ErrInvalidPolicy)
	}
	if len(input.AllowedChainIDs) == 0 {
		return PrivatePolicy{}, fmt.Errorf("allowedChainIds: %w", ErrInvalidPolicy)
	}
	if len(input.AuthorizedAgents) == 0 {
		return PrivatePolicy{}, fmt.Errorf("authorizedAgents: %w", ErrInvalidPolicy)
	}
	if len(input.Targets) == 0 {
		return PrivatePolicy{}, fmt.Errorf("targets: %w", ErrInvalidPolicy)
	}

	globalMax, parsedGlobalMax, err := normalizeDecimal(input.MaxNativeValue)
	if err != nil {
		return PrivatePolicy{}, fmt.Errorf("maxNativeValue: %w", err)
	}

	chains, err := normalizeChainIDs(input.AllowedChainIDs)
	if err != nil {
		return PrivatePolicy{}, err
	}

	agents := append([]common.Address(nil), input.AuthorizedAgents...)
	sortAddresses(agents)
	if err := ensureUniqueAddresses("authorizedAgents", agents); err != nil {
		return PrivatePolicy{}, err
	}

	targets := make([]TargetRule, len(input.Targets))
	for index, target := range input.Targets {
		normalized, err := normalizeTarget(target, parsedGlobalMax)
		if err != nil {
			return PrivatePolicy{}, err
		}
		targets[index] = normalized
	}
	sort.Slice(targets, func(i, j int) bool {
		return bytes.Compare(targets[i].Target[:], targets[j].Target[:]) < 0
	})
	for index := 1; index < len(targets); index++ {
		if targets[index].Target == targets[index-1].Target {
			return PrivatePolicy{}, fmt.Errorf("targets: %w", ErrDuplicateValue)
		}
	}

	return PrivatePolicy{
		SchemaVersion:               input.SchemaVersion,
		PolicyID:                    input.PolicyID,
		Owner:                       input.Owner,
		Account:                     input.Account,
		Version:                     input.Version,
		ValidAfter:                  input.ValidAfter,
		ValidUntil:                  input.ValidUntil,
		AllowedChainIDs:             chains,
		AuthorizedAgents:            agents,
		MaxNativeValue:              globalMax,
		MaxRiskScore:                input.MaxRiskScore,
		MaxSimulationBlockAge:       input.MaxSimulationBlockAge,
		RequireSuccessfulSimulation: input.RequireSuccessfulSimulation,
		RequireProviderAgreement:    input.RequireProviderAgreement,
		Targets:                     targets,
	}, nil
}

// FindTarget returns the normalized rule for target.
func FindTarget(normalized PrivatePolicy, target common.Address) (TargetRule, bool) {
	index := sort.Search(len(normalized.Targets), func(index int) bool {
		return bytes.Compare(normalized.Targets[index].Target[:], target[:]) >= 0
	})
	if index < len(normalized.Targets) && normalized.Targets[index].Target == target {
		return normalized.Targets[index], true
	}
	return TargetRule{}, false
}

// HasAuthorizedAgent reports whether agent is in the normalized allowlist.
func HasAuthorizedAgent(normalized PrivatePolicy, agent common.Address) bool {
	index := sort.Search(len(normalized.AuthorizedAgents), func(index int) bool {
		return bytes.Compare(normalized.AuthorizedAgents[index][:], agent[:]) >= 0
	})
	return index < len(normalized.AuthorizedAgents) && normalized.AuthorizedAgents[index] == agent
}

// HasAllowedRecipient reports whether recipient is allowed. An empty list means
// the target rule does not restrict recipients.
func HasAllowedRecipient(rule TargetRule, recipient common.Address) bool {
	if len(rule.AllowedRecipients) == 0 {
		return true
	}
	index := sort.Search(len(rule.AllowedRecipients), func(index int) bool {
		return bytes.Compare(rule.AllowedRecipients[index][:], recipient[:]) >= 0
	})
	return index < len(rule.AllowedRecipients) && rule.AllowedRecipients[index] == recipient
}

// HasSelector reports whether selector is allowed by the normalized rule.
func HasSelector(rule TargetRule, selector string) bool {
	if rule.AllowAnySelector {
		return true
	}
	index := sort.SearchStrings(rule.Selectors, selector)
	return index < len(rule.Selectors) && rule.Selectors[index] == selector
}
EOF

  cat > "$PROJECT_ROOT/go/pkg/policy/hash.go" <<'EOF'
package policy

import (
	"encoding/json"
	"fmt"

	"extension-scaffold/pkg/protocol"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
)

type canonicalChainScope struct {
	AllowedChainIDs []string `json:"allowedChainIds"`
}

type canonicalRules struct {
	SchemaVersion               uint16           `json:"schemaVersion"`
	AuthorizedAgents            []common.Address `json:"authorizedAgents"`
	MaxNativeValue              string           `json:"maxNativeValue"`
	MaxRiskScore                uint8            `json:"maxRiskScore"`
	MaxSimulationBlockAge       uint64           `json:"maxSimulationBlockAge"`
	RequireSuccessfulSimulation bool             `json:"requireSuccessfulSimulation"`
	RequireProviderAgreement    bool             `json:"requireProviderAgreement"`
	Targets                     []TargetRule      `json:"targets"`
}

// CanonicalRulesJSON returns the normalized byte-exact private-rules document.
func CanonicalRulesJSON(input PrivatePolicy) ([]byte, error) {
	normalized, err := Normalize(input)
	if err != nil {
		return nil, err
	}

	encoded, err := json.Marshal(canonicalRules{
		SchemaVersion:               normalized.SchemaVersion,
		AuthorizedAgents:            normalized.AuthorizedAgents,
		MaxNativeValue:              normalized.MaxNativeValue,
		MaxRiskScore:                normalized.MaxRiskScore,
		MaxSimulationBlockAge:       normalized.MaxSimulationBlockAge,
		RequireSuccessfulSimulation: normalized.RequireSuccessfulSimulation,
		RequireProviderAgreement:    normalized.RequireProviderAgreement,
		Targets:                     normalized.Targets,
	})
	if err != nil {
		return nil, fmt.Errorf("marshal canonical policy rules: %w", err)
	}
	return encoded, nil
}

// RulesHash commits to the confidential policy rules.
func RulesHash(input PrivatePolicy) (common.Hash, error) {
	encoded, err := CanonicalRulesJSON(input)
	if err != nil {
		return common.Hash{}, err
	}
	return crypto.Keccak256Hash(encoded), nil
}

// ChainScopeHash commits to the normalized set of allowed chains.
func ChainScopeHash(input PrivatePolicy) (common.Hash, error) {
	normalized, err := Normalize(input)
	if err != nil {
		return common.Hash{}, err
	}

	encoded, err := json.Marshal(canonicalChainScope{
		AllowedChainIDs: normalized.AllowedChainIDs,
	})
	if err != nil {
		return common.Hash{}, fmt.Errorf("marshal canonical chain scope: %w", err)
	}
	return crypto.Keccak256Hash(encoded), nil
}

// ValidateAgainstEnvelope proves that private plaintext matches its public
// onchain policy envelope.
func ValidateAgainstEnvelope(
	input PrivatePolicy,
	envelope protocol.PolicyEnvelope,
) (PrivatePolicy, error) {
	normalized, err := Normalize(input)
	if err != nil {
		return PrivatePolicy{}, err
	}
	if err := protocol.ValidatePolicyEnvelope(envelope); err != nil {
		return PrivatePolicy{}, fmt.Errorf("validate public envelope: %w", err)
	}

	if normalized.SchemaVersion != envelope.SchemaVersion ||
		normalized.PolicyID != envelope.PolicyID ||
		normalized.Owner != envelope.Owner ||
		normalized.Account != envelope.Account ||
		normalized.Version != envelope.PolicyVersion ||
		normalized.ValidAfter != envelope.ValidAfter ||
		normalized.ValidUntil != envelope.ValidUntil {
		return PrivatePolicy{}, fmt.Errorf("private policy identity does not match public envelope")
	}

	rulesHash, err := RulesHash(normalized)
	if err != nil {
		return PrivatePolicy{}, err
	}
	if rulesHash != envelope.RulesHash {
		return PrivatePolicy{}, fmt.Errorf("private rules hash does not match public envelope")
	}

	chainScopeHash, err := ChainScopeHash(normalized)
	if err != nil {
		return PrivatePolicy{}, err
	}
	if chainScopeHash != envelope.ChainScopeHash {
		return PrivatePolicy{}, fmt.Errorf("private chain scope does not match public envelope")
	}

	return normalized, nil
}
EOF

  cat > "$PROJECT_ROOT/go/pkg/policy/policy_test.go" <<'EOF'
package policy_test

import (
	"testing"

	"extension-scaffold/pkg/policy"
	"extension-scaffold/pkg/protocol"

	"github.com/ethereum/go-ethereum/common"
)

func TestPolicyHashesIgnoreInputOrdering(t *testing.T) {
	first := fixturePolicy()
	second := fixturePolicy()

	second.AllowedChainIDs[0], second.AllowedChainIDs[1] =
		second.AllowedChainIDs[1], second.AllowedChainIDs[0]
	second.AuthorizedAgents[0], second.AuthorizedAgents[1] =
		second.AuthorizedAgents[1], second.AuthorizedAgents[0]
	second.Targets[0].Selectors[0], second.Targets[0].Selectors[1] =
		second.Targets[0].Selectors[1], second.Targets[0].Selectors[0]
	second.Targets[0].AllowedRecipients[0], second.Targets[0].AllowedRecipients[1] =
		second.Targets[0].AllowedRecipients[1], second.Targets[0].AllowedRecipients[0]

	firstRules, err := policy.RulesHash(first)
	if err != nil {
		t.Fatal(err)
	}
	secondRules, err := policy.RulesHash(second)
	if err != nil {
		t.Fatal(err)
	}
	if firstRules != secondRules {
		t.Fatal("rules hash changed when unordered sets were reordered")
	}

	firstChains, err := policy.ChainScopeHash(first)
	if err != nil {
		t.Fatal(err)
	}
	secondChains, err := policy.ChainScopeHash(second)
	if err != nil {
		t.Fatal(err)
	}
	if firstChains != secondChains {
		t.Fatal("chain-scope hash changed when chains were reordered")
	}
}

func TestPolicyMatchesPublicEnvelope(t *testing.T) {
	privatePolicy := fixturePolicy()
	rulesHash, err := policy.RulesHash(privatePolicy)
	if err != nil {
		t.Fatal(err)
	}
	chainScopeHash, err := policy.ChainScopeHash(privatePolicy)
	if err != nil {
		t.Fatal(err)
	}

	envelope := protocol.PolicyEnvelope{
		ProtocolVersion: protocol.CurrentProtocolVersion,
		SchemaVersion:   policy.CurrentSchemaVersion,
		PolicyID:        privatePolicy.PolicyID,
		Owner:           privatePolicy.Owner,
		Account:         privatePolicy.Account,
		PolicyVersion:   privatePolicy.Version,
		ValidAfter:      privatePolicy.ValidAfter,
		ValidUntil:      privatePolicy.ValidUntil,
		ChainScopeHash:  chainScopeHash,
		RulesHash:       rulesHash,
		MetadataHash:    common.HexToHash("0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
	}

	if _, err := policy.ValidateAgainstEnvelope(privatePolicy, envelope); err != nil {
		t.Fatalf("valid policy rejected: %v", err)
	}

	privatePolicy.MaxNativeValue = "999"
	if _, err := policy.ValidateAgainstEnvelope(privatePolicy, envelope); err == nil {
		t.Fatal("mutated private rules matched the old public commitment")
	}
}

func TestDuplicateTargetsRejected(t *testing.T) {
	privatePolicy := fixturePolicy()
	privatePolicy.Targets = append(privatePolicy.Targets, privatePolicy.Targets[0])

	if _, err := policy.Normalize(privatePolicy); err == nil {
		t.Fatal("duplicate target was accepted")
	}
}

func fixturePolicy() policy.PrivatePolicy {
	return policy.PrivatePolicy{
		SchemaVersion:         policy.CurrentSchemaVersion,
		PolicyID:              common.HexToHash("0x1111111111111111111111111111111111111111111111111111111111111111"),
		Owner:                 common.HexToAddress("0x1111111111111111111111111111111111111111"),
		Account:               common.HexToAddress("0x2222222222222222222222222222222222222222"),
		Version:               1,
		ValidAfter:            100,
		ValidUntil:            10_000,
		AllowedChainIDs:       []string{"114", "14"},
		AuthorizedAgents:      []common.Address{
			common.HexToAddress("0x4444444444444444444444444444444444444444"),
			common.HexToAddress("0x3333333333333333333333333333333333333333"),
		},
		MaxNativeValue:              "1000000000000000000",
		MaxRiskScore:                0,
		MaxSimulationBlockAge:       64,
		RequireSuccessfulSimulation: true,
		RequireProviderAgreement:    true,
		Targets: []policy.TargetRule{
			{
				Target:                 common.HexToAddress("0x5555555555555555555555555555555555555555"),
				CodeHash:               common.HexToHash("0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
				Selectors:              []string{"0xa9059cbb", "0x095ea7b3"},
				MaxNativeValue:         "0",
				MaxERC20Transfer:       "100000000",
				MaxERC20Approval:       "100000000",
				AllowUnlimitedApproval: false,
				AllowedRecipients: []common.Address{
					common.HexToAddress("0x7777777777777777777777777777777777777777"),
					common.HexToAddress("0x6666666666666666666666666666666666666666"),
				},
			},
		},
	}
}
EOF
}

write_policy_engine() {
  mkdir -p "$PROJECT_ROOT/go/internal/policyengine"

  cat > "$PROJECT_ROOT/go/internal/policyengine/types.go" <<'EOF'
package policyengine

import (
	"extension-scaffold/pkg/policy"
	"extension-scaffold/pkg/protocol"

	"github.com/ethereum/go-ethereum/common"
)

// SimulationSnapshot is a deterministic, normalized simulation observation.
//
// A later provider layer will obtain and quorum-check these values. The engine
// consumes only this normalized representation.
type SimulationSnapshot struct {
	IntentHash          common.Hash
	BlockNumber         uint64
	BlockHash           common.Hash
	ObservedBlockNumber uint64
	EffectsHash         common.Hash
	Success             bool
	ProviderAgreement   bool
	TargetCodeHash      common.Hash
}

// Request contains every input needed for deterministic policy evaluation.
type Request struct {
	RequestID        common.Hash
	EvaluationTime   uint64
	PolicyEnvelope   protocol.PolicyEnvelope
	PrivatePolicy    policy.PrivatePolicy
	Intent           protocol.TransactionIntent
	Simulation       SimulationSnapshot
}

// Result contains the exact executor decision and stable explanations.
type Result struct {
	Decision           protocol.FirewallDecision
	DecisionHash       common.Hash
	PolicyCommitment   common.Hash
	RulesHash          common.Hash
	ChainScopeHash     common.Hash
	Reasons            []string
}
EOF

  cat > "$PROJECT_ROOT/go/internal/policyengine/erc20.go" <<'EOF'
package policyengine

import (
	"encoding/hex"
	"fmt"
	"math/big"

	"github.com/ethereum/go-ethereum/common"
)

const (
	selectorApprove      = "0x095ea7b3"
	selectorTransfer     = "0xa9059cbb"
	selectorTransferFrom = "0x23b872dd"
)

type tokenOperation struct {
	selector  string
	recipient common.Address
	amount    *big.Int
	known     bool
}

func selectorFromCalldata(data []byte) (string, error) {
	switch {
	case len(data) == 0:
		return "0x00000000", nil
	case len(data) < 4:
		return "", fmt.Errorf("calldata shorter than selector")
	default:
		return "0x" + hex.EncodeToString(data[:4]), nil
	}
}

func addressWord(data []byte, offset int) (common.Address, error) {
	if offset < 0 || len(data) < offset+32 {
		return common.Address{}, fmt.Errorf("missing ABI address word")
	}
	var address common.Address
	copy(address[:], data[offset+12:offset+32])
	return address, nil
}

func uintWord(data []byte, offset int) (*big.Int, error) {
	if offset < 0 || len(data) < offset+32 {
		return nil, fmt.Errorf("missing ABI uint256 word")
	}
	return new(big.Int).SetBytes(data[offset : offset+32]), nil
}

func decodeTokenOperation(data []byte, selector string) (tokenOperation, error) {
	switch selector {
	case selectorApprove, selectorTransfer:
		if len(data) != 68 {
			return tokenOperation{}, fmt.Errorf("expected 68-byte ERC20 calldata")
		}
		recipient, err := addressWord(data, 4)
		if err != nil {
			return tokenOperation{}, err
		}
		amount, err := uintWord(data, 36)
		if err != nil {
			return tokenOperation{}, err
		}
		return tokenOperation{
			selector:  selector,
			recipient: recipient,
			amount:    amount,
			known:     true,
		}, nil

	case selectorTransferFrom:
		if len(data) != 100 {
			return tokenOperation{}, fmt.Errorf("expected 100-byte ERC20 calldata")
		}
		recipient, err := addressWord(data, 36)
		if err != nil {
			return tokenOperation{}, err
		}
		amount, err := uintWord(data, 68)
		if err != nil {
			return tokenOperation{}, err
		}
		return tokenOperation{
			selector:  selector,
			recipient: recipient,
			amount:    amount,
			known:     true,
		}, nil

	default:
		return tokenOperation{selector: selector}, nil
	}
}
EOF

  cat > "$PROJECT_ROOT/go/internal/policyengine/engine.go" <<'EOF'
// Package policyengine evaluates private Sentinel policies deterministically.
package policyengine

import (
	"fmt"
	"math/big"

	"extension-scaffold/pkg/policy"
	"extension-scaffold/pkg/protocol"

	"github.com/ethereum/go-ethereum/common"
)

type accumulator struct {
	flags   *big.Int
	score   uint16
	reasons []string
}

func newAccumulator() *accumulator {
	return &accumulator{flags: new(big.Int)}
}

func (a *accumulator) add(flag protocol.RiskFlag, weight uint8, reason string) {
	if protocol.HasRiskFlag(a.flags, flag) {
		return
	}

	mask, err := flag.Mask()
	if err != nil {
		panic(err)
	}
	a.flags.Or(a.flags, mask)
	a.score += uint16(weight)
	if a.score > protocol.MaximumRiskScore {
		a.score = uint16(protocol.MaximumRiskScore)
	}
	a.reasons = append(a.reasons, reason)
}

func (a *accumulator) riskScore() uint8 {
	return uint8(a.score)
}

func containsChain(chains []string, chainID *big.Int) bool {
	if chainID == nil {
		return false
	}
	value := chainID.String()
	for _, chain := range chains {
		if chain == value {
			return true
		}
	}
	return false
}

func valueExceeds(value *big.Int, maximum string) bool {
	parsed, err := policy.ParseUint256(maximum)
	if err != nil {
		panic(err)
	}
	return value == nil || value.Cmp(parsed) > 0
}

func isMaxUint256(value *big.Int) bool {
	if value == nil {
		return false
	}
	return value.BitLen() == 256 && value.Cmp(new(big.Int).Sub(
		new(big.Int).Lsh(big.NewInt(1), 256),
		big.NewInt(1),
	)) == 0
}

func validateRequest(request Request) (
	policy.PrivatePolicy,
	common.Hash,
	common.Hash,
	common.Hash,
	common.Hash,
	error,
) {
	if request.RequestID == (common.Hash{}) {
		return policy.PrivatePolicy{}, common.Hash{}, common.Hash{}, common.Hash{}, common.Hash{},
			fmt.Errorf("requestId must not be zero")
	}
	if err := protocol.ValidateTransactionIntent(request.Intent); err != nil {
		return policy.PrivatePolicy{}, common.Hash{}, common.Hash{}, common.Hash{}, common.Hash{},
			fmt.Errorf("validate intent: %w", err)
	}

	normalized, err := policy.ValidateAgainstEnvelope(
		request.PrivatePolicy,
		request.PolicyEnvelope,
	)
	if err != nil {
		return policy.PrivatePolicy{}, common.Hash{}, common.Hash{}, common.Hash{}, common.Hash{},
			fmt.Errorf("validate policy commitment: %w", err)
	}

	intentHash, err := protocol.HashTransactionIntent(request.Intent)
	if err != nil {
		return policy.PrivatePolicy{}, common.Hash{}, common.Hash{}, common.Hash{}, common.Hash{},
			err
	}
	if request.Simulation.IntentHash != intentHash {
		return policy.PrivatePolicy{}, common.Hash{}, common.Hash{}, common.Hash{}, common.Hash{},
			fmt.Errorf("simulation intent hash does not match request intent")
	}

	policyCommitment, err := protocol.HashPolicyEnvelope(request.PolicyEnvelope)
	if err != nil {
		return policy.PrivatePolicy{}, common.Hash{}, common.Hash{}, common.Hash{}, common.Hash{},
			err
	}
	rulesHash, err := policy.RulesHash(normalized)
	if err != nil {
		return policy.PrivatePolicy{}, common.Hash{}, common.Hash{}, common.Hash{}, common.Hash{},
			err
	}
	chainScopeHash, err := policy.ChainScopeHash(normalized)
	if err != nil {
		return policy.PrivatePolicy{}, common.Hash{}, common.Hash{}, common.Hash{}, common.Hash{},
			err
	}

	return normalized, intentHash, policyCommitment, rulesHash, chainScopeHash, nil
}

// Evaluate applies the normalized private policy in a fixed, deterministic order.
func Evaluate(request Request) (Result, error) {
	normalized, intentHash, policyCommitment, rulesHash, chainScopeHash, err :=
		validateRequest(request)
	if err != nil {
		return Result{}, err
	}

	risk := newAccumulator()

	if request.EvaluationTime < normalized.ValidAfter ||
		request.EvaluationTime > normalized.ValidUntil ||
		request.EvaluationTime < request.Intent.ValidAfter ||
		request.EvaluationTime > request.Intent.ValidUntil {
		risk.add(protocol.RiskRequestExpired, 100, "policy or intent validity window is inactive")
	}

	if !containsChain(normalized.AllowedChainIDs, request.Intent.ChainID) {
		risk.add(protocol.RiskUnsupportedOperation, 100, "chain is not allowed by policy")
	}

	if !policy.HasAuthorizedAgent(normalized, request.Intent.Agent) {
		risk.add(protocol.RiskAgentUnauthorized, 100, "agent is not authorized by policy")
	}

	if valueExceeds(request.Intent.Value, normalized.MaxNativeValue) {
		risk.add(protocol.RiskTransferTooLarge, 90, "native value exceeds global policy limit")
	}

	targetRule, found := policy.FindTarget(normalized, request.Intent.Target)
	if !found {
		risk.add(protocol.RiskUnknownTarget, 100, "target is not present in policy")
	}

	if found {
		evaluateTarget(risk, targetRule, request.Intent)

		if targetRule.CodeHash != (common.Hash{}) &&
			request.Simulation.TargetCodeHash != targetRule.CodeHash {
			risk.add(protocol.RiskCodeHashMismatch, 100, "target code hash differs from policy")
		}
	}

	evaluateSimulation(risk, normalized, request.Simulation)

	approved := risk.riskScore() <= normalized.MaxRiskScore

	decision := protocol.FirewallDecision{
		ProtocolVersion:       protocol.CurrentProtocolVersion,
		DecisionVersion:       protocol.CurrentDecisionVersion,
		RequestID:             request.RequestID,
		IntentHash:            intentHash,
		PolicyID:              normalized.PolicyID,
		PolicyCommitment:      policyCommitment,
		PolicyVersion:         normalized.Version,
		ChainID:               new(big.Int).Set(request.Intent.ChainID),
		Executor:              request.Intent.Executor,
		Account:               request.Intent.Account,
		Agent:                 request.Intent.Agent,
		Nonce:                 request.Intent.Nonce,
		ValidAfter:            request.Intent.ValidAfter,
		ValidUntil:            request.Intent.ValidUntil,
		SimulationBlockNumber: request.Simulation.BlockNumber,
		SimulationBlockHash:   request.Simulation.BlockHash,
		SimulationHash:        request.Simulation.EffectsHash,
		Approved:              approved,
		RiskScore:             risk.riskScore(),
		RiskFlags:             new(big.Int).Set(risk.flags),
	}

	decisionHash, err := protocol.HashFirewallDecision(decision)
	if err != nil {
		return Result{}, fmt.Errorf("hash firewall decision: %w", err)
	}

	return Result{
		Decision:         decision,
		DecisionHash:     decisionHash,
		PolicyCommitment: policyCommitment,
		RulesHash:        rulesHash,
		ChainScopeHash:   chainScopeHash,
		Reasons:          append([]string(nil), risk.reasons...),
	}, nil
}

func evaluateTarget(
	risk *accumulator,
	rule policy.TargetRule,
	intent protocol.TransactionIntent,
) {
	if valueExceeds(intent.Value, rule.MaxNativeValue) {
		risk.add(protocol.RiskTransferTooLarge, 90, "native value exceeds target limit")
	}

	selector, err := selectorFromCalldata(intent.Data)
	if err != nil {
		risk.add(protocol.RiskMalformedCalldata, 100, "calldata is shorter than four-byte selector")
		return
	}

	if !policy.HasSelector(rule, selector) {
		risk.add(protocol.RiskSelectorNotAllowed, 100, "function selector is not allowed")
		return
	}

	operation, err := decodeTokenOperation(intent.Data, selector)
	if err != nil {
		risk.add(protocol.RiskMalformedCalldata, 100, "known token calldata is malformed")
		return
	}
	if !operation.known {
		return
	}

	if !policy.HasAllowedRecipient(rule, operation.recipient) {
		risk.add(protocol.RiskRecipientNotAllowed, 100, "token recipient or spender is not allowed")
	}

	switch operation.selector {
	case selectorApprove:
		if isMaxUint256(operation.amount) && !rule.AllowUnlimitedApproval {
			risk.add(protocol.RiskUnlimitedApproval, 100, "unlimited token approval is prohibited")
		}
		if valueExceeds(operation.amount, rule.MaxERC20Approval) {
			risk.add(protocol.RiskApprovalTooLarge, 100, "token approval exceeds target limit")
		}

	case selectorTransfer, selectorTransferFrom:
		if valueExceeds(operation.amount, rule.MaxERC20Transfer) {
			risk.add(protocol.RiskTransferTooLarge, 100, "token transfer exceeds target limit")
		}
	}
}

func evaluateSimulation(
	risk *accumulator,
	privatePolicy policy.PrivatePolicy,
	simulation SimulationSnapshot,
) {
	if simulation.BlockNumber == 0 ||
		simulation.BlockHash == (common.Hash{}) ||
		simulation.EffectsHash == (common.Hash{}) {
		risk.add(protocol.RiskSimulationFailed, 100, "simulation snapshot is incomplete")
		return
	}

	if simulation.ObservedBlockNumber <= simulation.BlockNumber {
		risk.add(protocol.RiskSimulationStale, 100, "simulation block is not historical")
	} else {
		age := simulation.ObservedBlockNumber - simulation.BlockNumber
		if age > privatePolicy.MaxSimulationBlockAge {
			risk.add(protocol.RiskSimulationStale, 100, "simulation block is older than policy limit")
		}
	}

	if privatePolicy.RequireSuccessfulSimulation && !simulation.Success {
		risk.add(protocol.RiskSimulationFailed, 100, "simulation execution failed")
	}
	if privatePolicy.RequireProviderAgreement && !simulation.ProviderAgreement {
		risk.add(protocol.RiskProviderDisagreement, 100, "simulation providers disagree")
	}

}
EOF

  cat > "$PROJECT_ROOT/go/internal/policyengine/engine_test.go" <<'EOF'
package policyengine_test

import (
	"encoding/hex"
	"math/big"
	"reflect"
	"testing"

	"extension-scaffold/internal/policyengine"
	"extension-scaffold/pkg/policy"
	"extension-scaffold/pkg/protocol"

	"github.com/ethereum/go-ethereum/common"
)

func TestAllowedTransferProducesDeterministicApproval(t *testing.T) {
	request := fixtureRequest(t)

	first, err := policyengine.Evaluate(request)
	if err != nil {
		t.Fatal(err)
	}
	second, err := policyengine.Evaluate(request)
	if err != nil {
		t.Fatal(err)
	}

	if !first.Decision.Approved {
		t.Fatalf("expected approval, reasons: %v", first.Reasons)
	}
	if first.Decision.RiskScore != 0 || first.Decision.RiskFlags.Sign() != 0 {
		t.Fatalf("unexpected risk: score=%d flags=%s", first.Decision.RiskScore, first.Decision.RiskFlags)
	}
	if first.DecisionHash != second.DecisionHash || !reflect.DeepEqual(first.Reasons, second.Reasons) {
		t.Fatal("identical inputs produced different outputs")
	}
}

func TestUnlimitedApprovalDenied(t *testing.T) {
	request := fixtureRequest(t)
	request.Intent.Data = approveCalldata(
		common.HexToAddress("0x7777777777777777777777777777777777777777"),
		new(big.Int).Sub(new(big.Int).Lsh(big.NewInt(1), 256), big.NewInt(1)),
	)
	intentHash, err := protocol.HashTransactionIntent(request.Intent)
	if err != nil {
		t.Fatal(err)
	}
	request.Simulation.IntentHash = intentHash

	result, err := policyengine.Evaluate(request)
	if err != nil {
		t.Fatal(err)
	}

	if result.Decision.Approved {
		t.Fatal("unlimited approval was approved")
	}
	if !protocol.HasRiskFlag(result.Decision.RiskFlags, protocol.RiskUnlimitedApproval) {
		t.Fatal("unlimited-approval flag missing")
	}
}

func TestPrivatePolicyMutationFailsCommitmentValidation(t *testing.T) {
	request := fixtureRequest(t)
	request.PrivatePolicy.MaxERC20HackForTest()
}

func TestUnknownTargetDenied(t *testing.T) {
	request := fixtureRequest(t)
	request.Intent.Target = common.HexToAddress("0x9999999999999999999999999999999999999999")
	intentHash, err := protocol.HashTransactionIntent(request.Intent)
	if err != nil {
		t.Fatal(err)
	}
	request.Simulation.IntentHash = intentHash

	result, err := policyengine.Evaluate(request)
	if err != nil {
		t.Fatal(err)
	}

	if result.Decision.Approved {
		t.Fatal("unknown target was approved")
	}
	if !protocol.HasRiskFlag(result.Decision.RiskFlags, protocol.RiskUnknownTarget) {
		t.Fatal("unknown-target flag missing")
	}
}

func TestPolicyCommitmentMismatchReturnsError(t *testing.T) {
	request := fixtureRequest(t)
	request.PrivatePolicy.MaxNativeValue = "1"

	if _, err := policyengine.Evaluate(request); err == nil {
		t.Fatal("mutated private policy matched old envelope")
	}
}

func TestCodeHashMismatchDenied(t *testing.T) {
	request := fixtureRequest(t)
	request.Simulation.TargetCodeHash =
		common.HexToHash("0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff")

	result, err := policyengine.Evaluate(request)
	if err != nil {
		t.Fatal(err)
	}

	if result.Decision.Approved {
		t.Fatal("code-hash mismatch was approved")
	}
	if !protocol.HasRiskFlag(result.Decision.RiskFlags, protocol.RiskCodeHashMismatch) {
		t.Fatal("code-hash flag missing")
	}
}

func fixtureRequest(t *testing.T) policyengine.Request {
	t.Helper()

	privatePolicy := policy.PrivatePolicy{
		SchemaVersion:         policy.CurrentSchemaVersion,
		PolicyID:              common.HexToHash("0x1111111111111111111111111111111111111111111111111111111111111111"),
		Owner:                 common.HexToAddress("0x1111111111111111111111111111111111111111"),
		Account:               common.HexToAddress("0x2222222222222222222222222222222222222222"),
		Version:               1,
		ValidAfter:            100,
		ValidUntil:            10_000,
		AllowedChainIDs:       []string{"114"},
		AuthorizedAgents:      []common.Address{
			common.HexToAddress("0x3333333333333333333333333333333333333333"),
		},
		MaxNativeValue:              "0",
		MaxRiskScore:                0,
		MaxSimulationBlockAge:       64,
		RequireSuccessfulSimulation: true,
		RequireProviderAgreement:    true,
		Targets: []policy.TargetRule{
			{
				Target:                 common.HexToAddress("0x5555555555555555555555555555555555555555"),
				CodeHash:               common.HexToHash("0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
				Selectors:              []string{"0xa9059cbb", "0x095ea7b3"},
				MaxNativeValue:         "0",
				MaxERC20Transfer:       "100000000",
				MaxERC20Approval:       "100000000",
				AllowUnlimitedApproval: false,
				AllowedRecipients: []common.Address{
					common.HexToAddress("0x7777777777777777777777777777777777777777"),
				},
			},
		},
	}

	rulesHash, err := policy.RulesHash(privatePolicy)
	if err != nil {
		t.Fatal(err)
	}
	chainScopeHash, err := policy.ChainScopeHash(privatePolicy)
	if err != nil {
		t.Fatal(err)
	}

	envelope := protocol.PolicyEnvelope{
		ProtocolVersion: protocol.CurrentProtocolVersion,
		SchemaVersion:   policy.CurrentSchemaVersion,
		PolicyID:        privatePolicy.PolicyID,
		Owner:           privatePolicy.Owner,
		Account:         privatePolicy.Account,
		PolicyVersion:   privatePolicy.Version,
		ValidAfter:      privatePolicy.ValidAfter,
		ValidUntil:      privatePolicy.ValidUntil,
		ChainScopeHash:  chainScopeHash,
		RulesHash:       rulesHash,
		MetadataHash:    common.HexToHash("0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
	}

	intent := protocol.TransactionIntent{
		ProtocolVersion: protocol.CurrentProtocolVersion,
		ChainID:         big.NewInt(114),
		Executor:        privatePolicy.Account,
		Account:         privatePolicy.Account,
		Agent:           privatePolicy.AuthorizedAgents[0],
		Target:          privatePolicy.Targets[0].Target,
		Value:           big.NewInt(0),
		Data: transferCalldata(
			privatePolicy.Targets[0].AllowedRecipients[0],
			big.NewInt(50_000_000),
		),
		Nonce:      0,
		ValidAfter: 100,
		ValidUntil: 5_000,
	}

	intentHash, err := protocol.HashTransactionIntent(intent)
	if err != nil {
		t.Fatal(err)
	}

	return policyengine.Request{
		RequestID:      common.HexToHash("0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"),
		EvaluationTime: 1_000,
		PolicyEnvelope: envelope,
		PrivatePolicy:  privatePolicy,
		Intent:         intent,
		Simulation: policyengine.SimulationSnapshot{
			IntentHash:          intentHash,
			BlockNumber:         900,
			BlockHash:           common.HexToHash("0xdddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"),
			ObservedBlockNumber: 901,
			EffectsHash:         common.HexToHash("0xcccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"),
			Success:             true,
			ProviderAgreement:   true,
			TargetCodeHash:      privatePolicy.Targets[0].CodeHash,
		},
	}
}

func transferCalldata(recipient common.Address, amount *big.Int) []byte {
	selector, _ := hex.DecodeString("a9059cbb")
	data := make([]byte, 68)
	copy(data[:4], selector)
	copy(data[4+12:4+32], recipient[:])
	amount.FillBytes(data[36:68])
	return data
}

func approveCalldata(spender common.Address, amount *big.Int) []byte {
	selector, _ := hex.DecodeString("095ea7b3")
	data := make([]byte, 68)
	copy(data[:4], selector)
	copy(data[4+12:4+32], spender[:])
	amount.FillBytes(data[36:68])
	return data
}
EOF

  # Remove a deliberately impossible placeholder method from the generated test.
  python3 - "$PROJECT_ROOT/go/internal/policyengine/engine_test.go" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
start = text.find("func TestPrivatePolicyMutationFailsCommitmentValidation")
if start != -1:
    end = text.find("\nfunc TestUnknownTargetDenied", start)
    if end == -1:
        raise SystemExit("could not remove placeholder test")
    text = text[:start] + text[end + 1 :]
path.write_text(text, encoding="utf-8")
PY
}

write_wire_types() {
  cat > "$PROJECT_ROOT/go/pkg/types/sentinel.go" <<'EOF'
package types

import (
	"fmt"
	"math/big"

	"extension-scaffold/pkg/policy"
	"extension-scaffold/pkg/protocol"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/common/hexutil"
)

// SentinelTransactionIntent is the JSON-safe representation of an intent.
type SentinelTransactionIntent struct {
	ProtocolVersion uint16         `json:"protocolVersion"`
	ChainID         string         `json:"chainId"`
	Executor        common.Address `json:"executor"`
	Account         common.Address `json:"account"`
	Agent           common.Address `json:"agent"`
	Target          common.Address `json:"target"`
	Value           string         `json:"value"`
	Data            hexutil.Bytes  `json:"data"`
	Nonce           uint64         `json:"nonce"`
	ValidAfter      uint64         `json:"validAfter"`
	ValidUntil      uint64         `json:"validUntil"`
}

// ToProtocol validates decimal values and returns the canonical protocol intent.
func (intent SentinelTransactionIntent) ToProtocol() (protocol.TransactionIntent, error) {
	chainID, err := policy.ParseUint256(intent.ChainID)
	if err != nil || chainID.Sign() == 0 {
		return protocol.TransactionIntent{}, fmt.Errorf("invalid chainId")
	}
	value, err := policy.ParseUint256(intent.Value)
	if err != nil {
		return protocol.TransactionIntent{}, fmt.Errorf("invalid value")
	}

	return protocol.TransactionIntent{
		ProtocolVersion: intent.ProtocolVersion,
		ChainID:         chainID,
		Executor:        intent.Executor,
		Account:         intent.Account,
		Agent:           intent.Agent,
		Target:          intent.Target,
		Value:           value,
		Data:            append([]byte(nil), intent.Data...),
		Nonce:           intent.Nonce,
		ValidAfter:      intent.ValidAfter,
		ValidUntil:      intent.ValidUntil,
	}, nil
}

// SentinelSimulationSnapshot is the JSON-safe normalized simulation input.
type SentinelSimulationSnapshot struct {
	IntentHash          common.Hash `json:"intentHash"`
	BlockNumber         uint64      `json:"blockNumber"`
	BlockHash           common.Hash `json:"blockHash"`
	ObservedBlockNumber uint64      `json:"observedBlockNumber"`
	EffectsHash         common.Hash `json:"effectsHash"`
	Success             bool        `json:"success"`
	ProviderAgreement   bool        `json:"providerAgreement"`
	TargetCodeHash      common.Hash `json:"targetCodeHash"`
}

// SentinelEvaluationRequest is decrypted and decoded only inside the extension.
type SentinelEvaluationRequest struct {
	RequestID      common.Hash               `json:"requestId"`
	PolicyEnvelope protocol.PolicyEnvelope    `json:"policyEnvelope"`
	PrivatePolicy  policy.PrivatePolicy       `json:"privatePolicy"`
	Intent         SentinelTransactionIntent  `json:"intent"`
	Simulation     SentinelSimulationSnapshot `json:"simulation"`
}

// SentinelFirewallDecision is safe for JavaScript and cross-language JSON.
type SentinelFirewallDecision struct {
	ProtocolVersion       uint16         `json:"protocolVersion"`
	DecisionVersion       uint16         `json:"decisionVersion"`
	RequestID             common.Hash    `json:"requestId"`
	IntentHash            common.Hash    `json:"intentHash"`
	PolicyID              common.Hash    `json:"policyId"`
	PolicyCommitment      common.Hash    `json:"policyCommitment"`
	PolicyVersion         uint64         `json:"policyVersion"`
	ChainID               string         `json:"chainId"`
	Executor              common.Address `json:"executor"`
	Account               common.Address `json:"account"`
	Agent                 common.Address `json:"agent"`
	Nonce                  uint64         `json:"nonce"`
	ValidAfter             uint64         `json:"validAfter"`
	ValidUntil             uint64         `json:"validUntil"`
	SimulationBlockNumber uint64         `json:"simulationBlockNumber"`
	SimulationBlockHash   common.Hash    `json:"simulationBlockHash"`
	SimulationHash        common.Hash    `json:"simulationHash"`
	Approved              bool           `json:"approved"`
	RiskScore             uint8          `json:"riskScore"`
	RiskFlags             string         `json:"riskFlags"`
}

// NewSentinelFirewallDecision converts a canonical decision to JSON-safe fields.
func NewSentinelFirewallDecision(
	decision protocol.FirewallDecision,
) SentinelFirewallDecision {
	chainID := "0"
	if decision.ChainID != nil {
		chainID = decision.ChainID.String()
	}
	riskFlags := "0"
	if decision.RiskFlags != nil {
		riskFlags = decision.RiskFlags.String()
	}

	return SentinelFirewallDecision{
		ProtocolVersion:       decision.ProtocolVersion,
		DecisionVersion:       decision.DecisionVersion,
		RequestID:             decision.RequestID,
		IntentHash:            decision.IntentHash,
		PolicyID:              decision.PolicyID,
		PolicyCommitment:      decision.PolicyCommitment,
		PolicyVersion:         decision.PolicyVersion,
		ChainID:               chainID,
		Executor:              decision.Executor,
		Account:               decision.Account,
		Agent:                 decision.Agent,
		Nonce:                 decision.Nonce,
		ValidAfter:            decision.ValidAfter,
		ValidUntil:            decision.ValidUntil,
		SimulationBlockNumber: decision.SimulationBlockNumber,
		SimulationBlockHash:   decision.SimulationBlockHash,
		SimulationHash:        decision.SimulationHash,
		Approved:              decision.Approved,
		RiskScore:             decision.RiskScore,
		RiskFlags:             riskFlags,
	}
}

// ToProtocol reconstructs the canonical decision.
func (decision SentinelFirewallDecision) ToProtocol() (protocol.FirewallDecision, error) {
	chainID, ok := new(big.Int).SetString(decision.ChainID, 10)
	if !ok || chainID.Sign() < 0 || chainID.BitLen() > 256 {
		return protocol.FirewallDecision{}, fmt.Errorf("invalid decision chainId")
	}
	riskFlags, ok := new(big.Int).SetString(decision.RiskFlags, 10)
	if !ok || riskFlags.Sign() < 0 || riskFlags.BitLen() > 256 {
		return protocol.FirewallDecision{}, fmt.Errorf("invalid decision riskFlags")
	}

	return protocol.FirewallDecision{
		ProtocolVersion:       decision.ProtocolVersion,
		DecisionVersion:       decision.DecisionVersion,
		RequestID:             decision.RequestID,
		IntentHash:            decision.IntentHash,
		PolicyID:              decision.PolicyID,
		PolicyCommitment:      decision.PolicyCommitment,
		PolicyVersion:         decision.PolicyVersion,
		ChainID:               chainID,
		Executor:              decision.Executor,
		Account:               decision.Account,
		Agent:                 decision.Agent,
		Nonce:                 decision.Nonce,
		ValidAfter:            decision.ValidAfter,
		ValidUntil:            decision.ValidUntil,
		SimulationBlockNumber: decision.SimulationBlockNumber,
		SimulationBlockHash:   decision.SimulationBlockHash,
		SimulationHash:        decision.SimulationHash,
		Approved:              decision.Approved,
		RiskScore:             decision.RiskScore,
		RiskFlags:             riskFlags,
	}, nil
}

// SentinelEvaluationResponse is returned in ActionResult.Data.
type SentinelEvaluationResponse struct {
	Decision         SentinelFirewallDecision `json:"decision"`
	DecisionHash     common.Hash              `json:"decisionHash"`
	PolicyCommitment common.Hash              `json:"policyCommitment"`
	RulesHash        common.Hash              `json:"rulesHash"`
	ChainScopeHash   common.Hash              `json:"chainScopeHash"`
	Reasons          []string                 `json:"reasons"`
}
EOF
}

write_decryptor_and_extension_handler() {
  cat > "$PROJECT_ROOT/go/internal/extension/decryptor.go" <<'EOF'
package extension

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

const (
	maxEncryptedRequestBytes = 256 * 1024
	maxDecryptedRequestBytes = 1024 * 1024
	decryptRequestTimeout    = 5 * time.Second
)

type requestDecryptor interface {
	Decrypt(context.Context, []byte) ([]byte, error)
}

type nodeDecryptor struct {
	endpoint string
	client   *http.Client
}

type decryptRequest struct {
	EncryptedMessage []byte `json:"encryptedMessage"`
}

type decryptResponse struct {
	DecryptedMessage []byte `json:"decryptedMessage"`
}

func newNodeDecryptor(signPort int) requestDecryptor {
	return &nodeDecryptor{
		endpoint: fmt.Sprintf("http://127.0.0.1:%d/decrypt", signPort),
		client: &http.Client{
			Timeout: decryptRequestTimeout,
		},
	}
}

func (decryptor *nodeDecryptor) Decrypt(
	ctx context.Context,
	ciphertext []byte,
) ([]byte, error) {
	if len(ciphertext) == 0 {
		return nil, fmt.Errorf("encrypted request must not be empty")
	}
	if len(ciphertext) > maxEncryptedRequestBytes {
		return nil, fmt.Errorf("encrypted request exceeds %d bytes", maxEncryptedRequestBytes)
	}

	body, err := json.Marshal(decryptRequest{EncryptedMessage: ciphertext})
	if err != nil {
		return nil, fmt.Errorf("encode decrypt request: %w", err)
	}

	request, err := http.NewRequestWithContext(
		ctx,
		http.MethodPost,
		decryptor.endpoint,
		bytes.NewReader(body),
	)
	if err != nil {
		return nil, fmt.Errorf("create decrypt request: %w", err)
	}
	request.Header.Set("Content-Type", "application/json")

	response, err := decryptor.client.Do(request)
	if err != nil {
		return nil, fmt.Errorf("call tee-node decrypt endpoint: %w", err)
	}
	defer response.Body.Close()

	if response.StatusCode != http.StatusOK {
		message, _ := io.ReadAll(io.LimitReader(response.Body, 4*1024))
		return nil, fmt.Errorf(
			"tee-node decrypt endpoint returned %d: %s",
			response.StatusCode,
			string(message),
		)
	}

	var decoded decryptResponse
	decoder := json.NewDecoder(io.LimitReader(response.Body, maxDecryptedRequestBytes))
	if err := decoder.Decode(&decoded); err != nil {
		return nil, fmt.Errorf("decode tee-node decrypt response: %w", err)
	}
	if len(decoded.DecryptedMessage) == 0 {
		return nil, fmt.Errorf("tee-node returned empty plaintext")
	}
	if len(decoded.DecryptedMessage) >= maxDecryptedRequestBytes {
		return nil, fmt.Errorf("decrypted request exceeds limit")
	}

	return decoded.DecryptedMessage, nil
}
EOF

  cat > "$PROJECT_ROOT/go/internal/extension/sentinel.go" <<'EOF'
package extension

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"

	"extension-scaffold/internal/config"
	"extension-scaffold/internal/policyengine"
	"extension-scaffold/pkg/types"

	"github.com/flare-foundation/go-flare-common/pkg/tee/instruction"
	teetypes "github.com/flare-foundation/tee-node/pkg/types"
	teeutils "github.com/flare-foundation/tee-node/pkg/utils"
)

func (e *Extension) processSentinel(
	action teetypes.Action,
	dataFixed *instruction.DataFixed,
) (int, []byte) {
	if dataFixed.OPCommand != teeutils.ToHash(config.OPCommandEvaluate) {
		return http.StatusNotImplemented, []byte(fmt.Sprintf(
			"unsupported op command: received %s, expected %s (%s)",
			dataFixed.OPCommand.Hex(),
			teeutils.ToHash(config.OPCommandEvaluate).Hex(),
			config.OPCommandEvaluate,
		))
	}

	result := e.processEvaluation(action, dataFixed)
	body, _ := json.Marshal(result)
	return http.StatusOK, body
}

func (e *Extension) processEvaluation(
	action teetypes.Action,
	dataFixed *instruction.DataFixed,
) teetypes.ActionResult {
	if e.decryptor == nil {
		return buildResult(
			action,
			dataFixed,
			nil,
			0,
			fmt.Errorf("request decryptor is not configured"),
		)
	}

	ctx, cancel := context.WithTimeout(context.Background(), decryptRequestTimeout)
	defer cancel()

	plaintext, err := e.decryptor.Decrypt(ctx, dataFixed.OriginalMessage)
	if err != nil {
		return buildResult(
			action,
			dataFixed,
			nil,
			0,
			fmt.Errorf("decrypting request: %w", err),
		)
	}

	var request types.SentinelEvaluationRequest
	decoder := json.NewDecoder(bytes.NewReader(plaintext))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&request); err != nil {
		return buildResult(
			action,
			dataFixed,
			nil,
			0,
			fmt.Errorf("decoding evaluation request: %w", err),
		)
	}
	if decoder.More() {
		return buildResult(
			action,
			dataFixed,
			nil,
			0,
			fmt.Errorf("decoding evaluation request: trailing JSON values"),
		)
	}

	intent, err := request.Intent.ToProtocol()
	if err != nil {
		return buildResult(
			action,
			dataFixed,
			nil,
			0,
			fmt.Errorf("converting evaluation intent: %w", err),
		)
	}

	result, err := policyengine.Evaluate(policyengine.Request{
		RequestID:      request.RequestID,
		EvaluationTime: dataFixed.Timestamp,
		PolicyEnvelope: request.PolicyEnvelope,
		PrivatePolicy:  request.PrivatePolicy,
		Intent:         intent,
		Simulation: policyengine.SimulationSnapshot{
			IntentHash:          request.Simulation.IntentHash,
			BlockNumber:         request.Simulation.BlockNumber,
			BlockHash:           request.Simulation.BlockHash,
			ObservedBlockNumber: request.Simulation.ObservedBlockNumber,
			EffectsHash:         request.Simulation.EffectsHash,
			Success:             request.Simulation.Success,
			ProviderAgreement:   request.Simulation.ProviderAgreement,
			TargetCodeHash:      request.Simulation.TargetCodeHash,
		},
	})
	if err != nil {
		return buildResult(
			action,
			dataFixed,
			nil,
			0,
			fmt.Errorf("evaluating policy: %w", err),
		)
	}

	response := types.SentinelEvaluationResponse{
		Decision:         types.NewSentinelFirewallDecision(result.Decision),
		DecisionHash:     result.DecisionHash,
		PolicyCommitment: result.PolicyCommitment,
		RulesHash:        result.RulesHash,
		ChainScopeHash:   result.ChainScopeHash,
		Reasons:          result.Reasons,
	}

	data, err := json.Marshal(response)
	if err != nil {
		return buildResult(
			action,
			dataFixed,
			nil,
			0,
			fmt.Errorf("encoding evaluation response: %w", err),
		)
	}

	return buildResult(action, dataFixed, data, 1, nil)
}
EOF

  python3 - "$PROJECT_ROOT/go/internal/config/config.go" "$PROJECT_ROOT/go/internal/extension/extension.go" <<'PY'
from pathlib import Path
import sys

config_path = Path(sys.argv[1])
config = config_path.read_text(encoding="utf-8")
config_anchor = '\tOPCommandSayGoodbye = "SAY_GOODBYE"\n'
config_addition = (
    '\n'
    '\tOPTypeSentinel    = "SENTINEL"\n'
    '\tOPCommandEvaluate = "EVALUATE"\n'
)
if "OPTypeSentinel" not in config:
    if config_anchor not in config:
        raise SystemExit("config.go greeting constants anchor was not found")
    config = config.replace(config_anchor, config_anchor + config_addition, 1)
config_path.write_text(config, encoding="utf-8")

extension_path = Path(sys.argv[2])
extension = extension_path.read_text(encoding="utf-8")

struct_anchor = "\tServer *http.Server\n"
if "\tdecryptor requestDecryptor\n" not in extension:
    if struct_anchor not in extension:
        raise SystemExit("Extension struct anchor was not found")
    extension = extension.replace(
        struct_anchor,
        struct_anchor + "\tdecryptor requestDecryptor\n",
        1,
    )

new_anchor = "\te := &Extension{}\n"
new_value = "\te := &Extension{decryptor: newNodeDecryptor(signPort)}\n"
if new_value not in extension:
    if new_anchor not in extension:
        raise SystemExit("New constructor anchor was not found")
    extension = extension.replace(new_anchor, new_value, 1)

route_anchor = (
    "\tcase dataFixed.OPType == teeutils.ToHash(config.OPTypeGreeting):\n"
    "\t\treturn e.processGreeting(action, dataFixed)\n"
)
route_addition = (
    "\n"
    "\tcase dataFixed.OPType == teeutils.ToHash(config.OPTypeSentinel):\n"
    "\t\treturn e.processSentinel(action, dataFixed)\n"
)
if "return e.processSentinel(action, dataFixed)" not in extension:
    if route_anchor not in extension:
        raise SystemExit("processAction greeting route anchor was not found")
    extension = extension.replace(route_anchor, route_anchor + route_addition, 1)

extension_path.write_text(extension, encoding="utf-8")
PY
}

extend_instruction_sender() {
  python3 - "$PROJECT_ROOT/contracts/InstructionSender.sol" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

constant_anchor = (
    '    bytes32 public constant OP_COMMAND_SAY_GOODBYE = bytes32("SAY_GOODBYE");\n'
)
constant_addition = '''
    /// @notice Operation type for confidential Sentinel evaluations.
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes32 public constant OP_TYPE_SENTINEL = bytes32("SENTINEL");
    /// @notice Command for deterministic private-policy evaluation.
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes32 public constant OP_COMMAND_EVALUATE = bytes32("EVALUATE");
'''
if "OP_TYPE_SENTINEL" not in text:
    if constant_anchor not in text:
        raise SystemExit("InstructionSender command constant anchor was not found")
    text = text.replace(constant_anchor, constant_anchor + constant_addition, 1)

function_anchor = "    /// @notice Returns the cached extension ID, reverting if not yet set.\n"
function_addition = '''
    /// @notice Sends a request encrypted to one explicitly selected TEE.
    /// @dev The caller must obtain the selected TEE's public key and encrypt the
    ///      complete evaluation request before submitting this transaction.
    /// @param _teeId TEE machine whose public key encrypted the request.
    /// @param _encryptedRequest Ciphertext only; private policy plaintext must
    ///        never be included in transaction calldata.
    function sendEvaluation(address _teeId, bytes calldata _encryptedRequest) external payable {
        require(_teeId != address(0), "TEE id cannot be zero");
        require(_encryptedRequest.length != 0, "Encrypted request cannot be empty");

        address[] memory teeIds = new address[](1);
        teeIds[0] = _teeId;
        address[] memory cosigners = new address[](0);

        ITeeExtensionRegistry.TeeInstructionParams memory params = ITeeExtensionRegistry.TeeInstructionParams({
            opType: OP_TYPE_SENTINEL,
            opCommand: OP_COMMAND_EVALUATE,
            message: _encryptedRequest,
            cosigners: cosigners,
            cosignersThreshold: 0,
            claimBackAddress: msg.sender
        });

        TEE_EXTENSION_REGISTRY.sendInstructions{value: msg.value}(teeIds, params);
    }

'''
if "function sendEvaluation(" not in text:
    if function_anchor not in text:
        raise SystemExit("InstructionSender _getExtensionId anchor was not found")
    text = text.replace(function_anchor, function_addition + function_anchor, 1)

path.write_text(text, encoding="utf-8")
PY
}

write_extension_tests() {
  cat > "$PROJECT_ROOT/go/internal/extension/sentinel_test.go" <<'EOF'
package extension

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"math/big"
	"net/http"
	"testing"

	"extension-scaffold/internal/config"
	"extension-scaffold/pkg/policy"
	"extension-scaffold/pkg/protocol"
	"extension-scaffold/pkg/types"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/common/hexutil"
	teetypes "github.com/flare-foundation/tee-node/pkg/types"
	teeutils "github.com/flare-foundation/tee-node/pkg/utils"
)

type passthroughDecryptor struct{}

func (passthroughDecryptor) Decrypt(_ context.Context, ciphertext []byte) ([]byte, error) {
	return append([]byte(nil), ciphertext...), nil
}

func TestProcessSentinelEvaluationApprovesAllowedTransfer(t *testing.T) {
	request := sentinelFixture(t)
	payload, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}

	extension := &Extension{decryptor: passthroughDecryptor{}}
	action := buildTestAction(
		teeutils.ToHash(config.OPTypeSentinel),
		teeutils.ToHash(config.OPCommandEvaluate),
		payload,
	)

	status, body := extension.processAction(action)
	if status != http.StatusOK {
		t.Fatalf("expected HTTP 200, got %d: %s", status, body)
	}

	var actionResult teetypes.ActionResult
	if err := json.Unmarshal(body, &actionResult); err != nil {
		t.Fatal(err)
	}
	if actionResult.Status != 1 {
		t.Fatalf("evaluation failed: %s", actionResult.Log)
	}

	var response types.SentinelEvaluationResponse
	if err := json.Unmarshal(actionResult.Data, &response); err != nil {
		t.Fatal(err)
	}
	if !response.Decision.Approved {
		t.Fatalf("expected approved decision, reasons: %v", response.Reasons)
	}

	decision, err := response.Decision.ToProtocol()
	if err != nil {
		t.Fatal(err)
	}
	hash, err := protocol.HashFirewallDecision(decision)
	if err != nil {
		t.Fatal(err)
	}
	if hash != response.DecisionHash {
		t.Fatal("wire response decision hash does not match canonical decision")
	}
}

func TestProcessSentinelRejectsUnknownJSONField(t *testing.T) {
	extension := &Extension{decryptor: passthroughDecryptor{}}
	action := buildTestAction(
		teeutils.ToHash(config.OPTypeSentinel),
		teeutils.ToHash(config.OPCommandEvaluate),
		[]byte(`{"unknown":true}`),
	)

	status, body := extension.processAction(action)
	if status != http.StatusOK {
		t.Fatalf("expected routed handler HTTP 200, got %d", status)
	}

	var actionResult teetypes.ActionResult
	if err := json.Unmarshal(body, &actionResult); err != nil {
		t.Fatal(err)
	}
	if actionResult.Status != 0 {
		t.Fatal("invalid evaluation JSON was accepted")
	}
}

func sentinelFixture(t *testing.T) types.SentinelEvaluationRequest {
	t.Helper()

	privatePolicy := policy.PrivatePolicy{
		SchemaVersion:         policy.CurrentSchemaVersion,
		PolicyID:              common.HexToHash("0x1111111111111111111111111111111111111111111111111111111111111111"),
		Owner:                 common.HexToAddress("0x1111111111111111111111111111111111111111"),
		Account:               common.HexToAddress("0x2222222222222222222222222222222222222222"),
		Version:               1,
		ValidAfter:            0,
		ValidUntil:            10_000,
		AllowedChainIDs:       []string{"114"},
		AuthorizedAgents:      []common.Address{
			common.HexToAddress("0x3333333333333333333333333333333333333333"),
		},
		MaxNativeValue:              "0",
		MaxRiskScore:                0,
		MaxSimulationBlockAge:       64,
		RequireSuccessfulSimulation: true,
		RequireProviderAgreement:    true,
		Targets: []policy.TargetRule{
			{
				Target:                 common.HexToAddress("0x5555555555555555555555555555555555555555"),
				CodeHash:               common.HexToHash("0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
				Selectors:              []string{"0xa9059cbb"},
				MaxNativeValue:         "0",
				MaxERC20Transfer:       "100000000",
				MaxERC20Approval:       "0",
				AllowUnlimitedApproval: false,
				AllowedRecipients: []common.Address{
					common.HexToAddress("0x7777777777777777777777777777777777777777"),
				},
			},
		},
	}

	rulesHash, err := policy.RulesHash(privatePolicy)
	if err != nil {
		t.Fatal(err)
	}
	chainScopeHash, err := policy.ChainScopeHash(privatePolicy)
	if err != nil {
		t.Fatal(err)
	}

	calldata := make([]byte, 68)
	selector, _ := hex.DecodeString("a9059cbb")
	copy(calldata[:4], selector)
	recipient := privatePolicy.Targets[0].AllowedRecipients[0]
	copy(calldata[16:36], recipient[:])
	big.NewInt(50_000_000).FillBytes(calldata[36:68])

	wireIntent := types.SentinelTransactionIntent{
		ProtocolVersion: protocol.CurrentProtocolVersion,
		ChainID:         "114",
		Executor:        privatePolicy.Account,
		Account:         privatePolicy.Account,
		Agent:           privatePolicy.AuthorizedAgents[0],
		Target:          privatePolicy.Targets[0].Target,
		Value:           "0",
		Data:            hexutil.Bytes(calldata),
		Nonce:           0,
		ValidAfter:      0,
		ValidUntil:      5_000,
	}
	intent, err := wireIntent.ToProtocol()
	if err != nil {
		t.Fatal(err)
	}
	intentHash, err := protocol.HashTransactionIntent(intent)
	if err != nil {
		t.Fatal(err)
	}

	return types.SentinelEvaluationRequest{
		RequestID: common.HexToHash("0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"),
		PolicyEnvelope: protocol.PolicyEnvelope{
			ProtocolVersion: protocol.CurrentProtocolVersion,
			SchemaVersion:   policy.CurrentSchemaVersion,
			PolicyID:        privatePolicy.PolicyID,
			Owner:           privatePolicy.Owner,
			Account:         privatePolicy.Account,
			PolicyVersion:   privatePolicy.Version,
			ValidAfter:      privatePolicy.ValidAfter,
			ValidUntil:      privatePolicy.ValidUntil,
			ChainScopeHash:  chainScopeHash,
			RulesHash:       rulesHash,
			MetadataHash:    common.HexToHash("0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
		},
		PrivatePolicy: privatePolicy,
		Intent:        wireIntent,
		Simulation: types.SentinelSimulationSnapshot{
			IntentHash:          intentHash,
			BlockNumber:         900,
			BlockHash:           common.HexToHash("0xdddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"),
			ObservedBlockNumber: 901,
			EffectsHash:         common.HexToHash("0xcccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"),
			Success:             true,
			ProviderAgreement:   true,
			TargetCodeHash:      privatePolicy.Targets[0].CodeHash,
		},
	}
}
EOF

  cat > "$PROJECT_ROOT/go/internal/extension/decryptor_test.go" <<'EOF'
package extension

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestNodeDecryptorUsesBase64JSONWireFormat(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		var payload decryptRequest
		if err := json.NewDecoder(request.Body).Decode(&payload); err != nil {
			t.Fatal(err)
		}
		if string(payload.EncryptedMessage) != "ciphertext" {
			t.Fatalf("unexpected ciphertext: %q", payload.EncryptedMessage)
		}
		_ = json.NewEncoder(writer).Encode(decryptResponse{
			DecryptedMessage: []byte("plaintext"),
		})
	}))
	defer server.Close()

	decryptor := &nodeDecryptor{
		endpoint: server.URL,
		client:   server.Client(),
	}
	plaintext, err := decryptor.Decrypt(context.Background(), []byte("ciphertext"))
	if err != nil {
		t.Fatal(err)
	}
	if string(plaintext) != "plaintext" {
		t.Fatalf("unexpected plaintext: %q", plaintext)
	}
}
EOF
}

write_documentation() {
  cat > "$PROJECT_ROOT/docs/confidential-policy-engine.md" <<'EOF'
# Confidential Policy Engine

## Data boundary

The public chain stores only:

- policy identity and version;
- owner and protected account;
- validity window;
- chain-scope commitment;
- private-rules commitment;
- metadata commitment.

The private policy itself is encrypted to a specifically selected TEE. The
`InstructionSender` sends only ciphertext. Inside the extension, the ciphertext
is passed to tee-node's loopback `/decrypt` endpoint; plaintext is decoded and
evaluated only after decryption.

## Canonical private policy

Policy v1 includes:

- allowed chain IDs;
- authorized agent addresses;
- global native-value limit;
- maximum acceptable risk score;
- maximum simulation-block age;
- simulation-success and provider-agreement requirements;
- exact target allowlist;
- optional target code hashes;
- selector allowlists;
- per-target native-value limits;
- ERC-20 transfer and approval limits;
- unlimited-approval policy;
- recipient/spender allowlists.

Sets are sorted, duplicates are rejected, uint256 values use canonical decimal
strings, and selectors use lowercase `0x` plus eight hex digits. The normalized
JSON field order is fixed by the Go schema.

Two hashes are calculated:

```text
rulesHash      = keccak256(canonical private-rules JSON)
chainScopeHash = keccak256(canonical allowed-chain JSON)
```

Both must match the public `PolicyEnvelope`. A mutated plaintext policy cannot
reuse an old onchain commitment.

## Deterministic evaluation order

The engine evaluates inputs in a fixed order:

1. validity windows;
2. chain scope;
3. agent authorization;
4. global native-value limit;
5. target lookup;
6. target value and selector rules;
7. strict ERC-20 decoding and limits;
8. target code-hash binding;
9. simulation completeness, age, success, and provider agreement.

Risk flags and reasons are inserted in that same order. Repeating an identical
request produces the same decision and decision hash.

## Current trust boundary

Patch 006 consumes a normalized simulation snapshot. The engine validates its
binding to the exact intent, but it does not yet fetch RPC state itself. The next
simulation-provider layer will obtain traces from independent providers,
normalize effects, and set `providerAgreement`.

The extension returns the canonical firewall decision in `ActionResult.Data`.
FCC signs the result envelope. Bridging that attested result into the executor's
decision-verifier interface is a separate integration layer.
EOF

  python3 - "$PROJECT_ROOT/README.md" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
entry = "- [Confidential policy engine](docs/confidential-policy-engine.md)\n"
anchor = "- [Onchain policy and execution boundary](docs/onchain-enforcement.md)\n"

if entry not in text:
    if anchor not in text:
        raise SystemExit("README onchain enforcement anchor was not found")
    text = text.replace(anchor, anchor + entry, 1)

path.write_text(text, encoding="utf-8")
PY
}

archive_patch() {
  mkdir -p "$PROJECT_ROOT/scripts/patches"
  cp "$SCRIPT_PATH" "$PROJECT_ROOT/$ARCHIVE_RELATIVE_PATH"
  chmod 0755 "$PROJECT_ROOT/$ARCHIVE_RELATIVE_PATH"

  if [[ "$(dirname -- "$SCRIPT_PATH")" == "$PROJECT_ROOT" && "$SCRIPT_PATH" != "$PROJECT_ROOT/$ARCHIVE_RELATIVE_PATH" ]]; then
    rm -f "$SCRIPT_PATH"
  fi
}

format_and_verify() {
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

allowed_prefixes = (
    "go/pkg/policy/",
    "go/internal/policyengine/",
)
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
    "go/pkg/types/sentinel.go",
    "scripts/patches/006-confidential-policy-engine.sh",
}

status = subprocess.check_output(
    ["git", "status", "--porcelain=v1", "--untracked-files=all"],
    text=True,
).splitlines()

unexpected = []
for line in status:
    path = line[3:]
    if path in allowed or path.startswith(allowed_prefixes):
        continue
    unexpected.append(line)

if unexpected:
    raise SystemExit(
        "Unexpected files in Patch 006 change set:\n  "
        + "\n  ".join(unexpected)
    )
PY

  ok "Patch 006 changed only intended files."
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

  git add "$ARCHIVE_RELATIVE_PATH"
  git diff --cached --check
  git commit -m "chore(project): archive confidential policy patch"

  [[ -z "$(git status --porcelain=v1)" ]] ||
    die "Working tree is not clean after Patch 006 commits."

  ok "Created six atomic Patch 006 commits."
}

push_feature_branch() {
  cd "$PROJECT_ROOT"
  git push -u origin "$FEATURE_BRANCH"

  printf '\n'
  ok "Patch 006 completed and pushed."
  printf 'Branch: %s\n' "$FEATURE_BRANCH"
  printf 'Head:   %s\n' "$(git rev-parse --short HEAD)"
  printf 'Base:   %s\n' "$BASE_BRANCH"
  printf '\nCommits:\n'
  git log --oneline "origin/$BASE_BRANCH..HEAD"
  printf '\nPull request:\n'
  printf 'https://github.com/prateushsharma/sentinel-fcc/compare/%s...%s?expand=1\n' \
    "$BASE_BRANCH" "$FEATURE_BRANCH"
  printf '\nNext stage: quorum simulation providers and normalized effect extraction.\n'
}

main() {
  require_command git
  require_command go
  require_command gofmt
  require_command forge
  require_command python3
  require_command shellcheck

  validate_and_create_branch

  cd "$PROJECT_ROOT"
  write_policy_package
  write_policy_engine
  write_wire_types
  write_decryptor_and_extension_handler
  extend_instruction_sender
  write_extension_tests
  write_documentation
  archive_patch

  format_and_verify
  verify_change_set
  commit_atomic_history
  push_feature_branch
}

main "$@"
