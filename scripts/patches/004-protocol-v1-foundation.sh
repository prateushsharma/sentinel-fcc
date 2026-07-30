#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

readonly EXPECTED_ORIGIN_SLUG="prateushsharma/sentinel-fcc"
readonly BASE_BRANCH="develop"
readonly FEATURE_BRANCH="feat/protocol-v1-foundation"
readonly ARCHIVE_RELATIVE_PATH="scripts/patches/004-protocol-v1-foundation.sh"

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

validate_and_create_branch() {
  local branch origin_url origin_slug status_line

  [[ -d "$PROJECT_ROOT/.git" ]] || die "Not a Git repository: $PROJECT_ROOT"

  branch="$(git -C "$PROJECT_ROOT" branch --show-current)"
  [[ "$branch" == "$BASE_BRANCH" ]] ||
    die "Run Patch 004 from '$BASE_BRANCH'; current branch is '$branch'."

  origin_url="$(git -C "$PROJECT_ROOT" remote get-url origin 2>/dev/null || true)"
  origin_slug="$(normalize_github_slug "$origin_url")"
  [[ "$origin_slug" == "$EXPECTED_ORIGIN_SLUG" ]] ||
    die "Unexpected origin remote: $origin_url"

  git -C "$PROJECT_ROOT" fetch origin "$BASE_BRANCH" --prune

  [[ "$(git -C "$PROJECT_ROOT" rev-parse HEAD)" == "$(git -C "$PROJECT_ROOT" rev-parse "origin/$BASE_BRANCH")" ]] ||
    die "Local $BASE_BRANCH is not synchronized with origin/$BASE_BRANCH."

  while IFS= read -r status_line; do
    [[ -z "$status_line" ]] && continue
    if [[ "$(dirname -- "$SCRIPT_PATH")" == "$PROJECT_ROOT" && "$status_line" == "?? $SCRIPT_BASENAME" ]]; then
      continue
    fi
    printf '%s\n' "$status_line" >&2
    die "Working tree contains unrelated changes."
  done < <(git -C "$PROJECT_ROOT" status --porcelain=v1 --untracked-files=all)

  if git -C "$PROJECT_ROOT" show-ref --verify --quiet "refs/heads/$FEATURE_BRANCH"; then
    die "Local branch already exists: $FEATURE_BRANCH"
  fi

  if git -C "$PROJECT_ROOT" ls-remote --exit-code --heads origin "$FEATURE_BRANCH" >/dev/null 2>&1; then
    die "Remote branch already exists: $FEATURE_BRANCH"
  fi

  git -C "$PROJECT_ROOT" switch -c "$FEATURE_BRANCH"
  ok "Created feature branch: $FEATURE_BRANCH"
}

write_go_protocol_sources() {
  mkdir -p "$PROJECT_ROOT/go/pkg/protocol"

  cat > "$PROJECT_ROOT/go/pkg/protocol/doc.go" <<'EOF'
// Package protocol defines SentinelFCC's versioned canonical messages.
//
// Hashes produced by this package are ABI-compatible Solidity struct hashes.
// They are not final EIP-712 signing digests; the onchain verifier will later
// combine them with a chain- and contract-scoped EIP-712 domain.
package protocol
EOF

  cat > "$PROJECT_ROOT/go/pkg/protocol/version.go" <<'EOF'
package protocol

const (
	// CurrentProtocolVersion identifies the canonical Sentinel message family.
	CurrentProtocolVersion uint16 = 1

	// CurrentPolicySchemaVersion identifies the private policy-envelope schema.
	CurrentPolicySchemaVersion uint16 = 1

	// CurrentDecisionVersion identifies the firewall-decision schema.
	CurrentDecisionVersion uint16 = 1

	// MaximumRiskScore is the inclusive upper bound for normalized risk scores.
	MaximumRiskScore uint8 = 100
)
EOF

  cat > "$PROJECT_ROOT/go/pkg/protocol/types.go" <<'EOF'
package protocol

import (
	"math/big"

	"github.com/ethereum/go-ethereum/common"
)

// PolicyEnvelope is the public, hashable envelope around a private policy.
//
// RulesHash commits to the canonical private rules representation.
// MetadataHash commits to optional encrypted/offchain metadata.
// ChainScopeHash commits to the policy's allowed chain set.
type PolicyEnvelope struct {
	ProtocolVersion uint16
	SchemaVersion   uint16
	PolicyID        common.Hash
	Owner           common.Address
	Account         common.Address
	PolicyVersion   uint64
	ValidAfter      uint64
	ValidUntil      uint64
	ChainScopeHash  common.Hash
	RulesHash       common.Hash
	MetadataHash    common.Hash
}

// TransactionIntent is the exact call proposed by an autonomous agent.
//
// ChainID and Value are uint256 values in the canonical Solidity encoding.
// Data is never encoded directly into the struct hash; its Keccak-256 digest is.
type TransactionIntent struct {
	ProtocolVersion uint16
	ChainID         *big.Int
	Executor        common.Address
	Account         common.Address
	Agent           common.Address
	Target          common.Address
	Value           *big.Int
	Data            []byte
	Nonce           uint64
	ValidAfter      uint64
	ValidUntil      uint64
}

// EvaluationRequest binds an authenticated request to an active policy and one
// exact transaction-intent hash.
type EvaluationRequest struct {
	ProtocolVersion  uint16
	RequestID        common.Hash
	PolicyID         common.Hash
	PolicyCommitment common.Hash
	PolicyVersion    uint64
	IntentHash       common.Hash
	RequestedAt      uint64
}

// FirewallDecision is the TEE-produced authorization payload consumed onchain.
//
// SimulationHash commits to normalized effects; raw traces remain confidential.
// RiskFlags is encoded as a Solidity uint256.
type FirewallDecision struct {
	ProtocolVersion       uint16
	DecisionVersion       uint16
	RequestID             common.Hash
	IntentHash            common.Hash
	PolicyID              common.Hash
	PolicyCommitment      common.Hash
	PolicyVersion         uint64
	ChainID               *big.Int
	Executor              common.Address
	Account               common.Address
	Agent                 common.Address
	Nonce                 uint64
	ValidAfter            uint64
	ValidUntil            uint64
	SimulationBlockNumber uint64
	SimulationBlockHash   common.Hash
	SimulationHash        common.Hash
	Approved              bool
	RiskScore             uint8
	RiskFlags             *big.Int
}
EOF

  cat > "$PROJECT_ROOT/go/pkg/protocol/risk.go" <<'EOF'
package protocol

import (
	"fmt"
	"math/big"
)

// RiskFlag identifies one bit in FirewallDecision.RiskFlags.
type RiskFlag uint8

const (
	RiskUnknownTarget RiskFlag = iota
	RiskSelectorNotAllowed
	RiskUnlimitedApproval
	RiskApprovalTooLarge
	RiskTransferTooLarge
	RiskRecipientNotAllowed
	RiskSimulationFailed
	RiskSimulationStale
	RiskProviderDisagreement
	RiskMalformedCalldata
	RiskUnsupportedOperation
	RiskPolicyMissing
	RiskPolicyRevoked
	RiskAgentUnauthorized
	RiskRequestExpired
	RiskNonceReused
	RiskCodeHashMismatch
	RiskNestedCallOpaque

	riskFlagCount
)

var riskFlagNames = map[RiskFlag]string{
	RiskUnknownTarget:        "UNKNOWN_TARGET",
	RiskSelectorNotAllowed:   "SELECTOR_NOT_ALLOWED",
	RiskUnlimitedApproval:    "UNLIMITED_APPROVAL",
	RiskApprovalTooLarge:     "APPROVAL_TOO_LARGE",
	RiskTransferTooLarge:     "TRANSFER_TOO_LARGE",
	RiskRecipientNotAllowed:  "RECIPIENT_NOT_ALLOWED",
	RiskSimulationFailed:     "SIMULATION_FAILED",
	RiskSimulationStale:      "SIMULATION_STALE",
	RiskProviderDisagreement: "PROVIDER_DISAGREEMENT",
	RiskMalformedCalldata:    "MALFORMED_CALLDATA",
	RiskUnsupportedOperation: "UNSUPPORTED_OPERATION",
	RiskPolicyMissing:        "POLICY_MISSING",
	RiskPolicyRevoked:        "POLICY_REVOKED",
	RiskAgentUnauthorized:    "AGENT_UNAUTHORIZED",
	RiskRequestExpired:       "REQUEST_EXPIRED",
	RiskNonceReused:          "NONCE_REUSED",
	RiskCodeHashMismatch:     "CODE_HASH_MISMATCH",
	RiskNestedCallOpaque:     "NESTED_CALL_OPAQUE",
}

// String returns the stable machine-readable name of the flag.
func (f RiskFlag) String() string {
	if name, ok := riskFlagNames[f]; ok {
		return name
	}
	return fmt.Sprintf("UNKNOWN_RISK_FLAG_%d", uint8(f))
}

// Mask returns a fresh uint256-compatible bit mask for the flag.
func (f RiskFlag) Mask() (*big.Int, error) {
	if f >= riskFlagCount {
		return nil, fmt.Errorf("risk flag %d is out of range", f)
	}
	return new(big.Int).Lsh(big.NewInt(1), uint(f)), nil
}

// CombineRiskFlags combines flags into a fresh uint256-compatible mask.
func CombineRiskFlags(flags ...RiskFlag) (*big.Int, error) {
	mask := new(big.Int)
	for _, flag := range flags {
		bit, err := flag.Mask()
		if err != nil {
			return nil, err
		}
		mask.Or(mask, bit)
	}
	return mask, nil
}

// HasRiskFlag reports whether mask contains flag.
func HasRiskFlag(mask *big.Int, flag RiskFlag) bool {
	if mask == nil || flag >= riskFlagCount {
		return false
	}
	return mask.Bit(int(flag)) == 1
}
EOF

  cat > "$PROJECT_ROOT/go/pkg/protocol/validation.go" <<'EOF'
package protocol

import (
	"errors"
	"fmt"
	"math/big"

	"github.com/ethereum/go-ethereum/common"
)

var (
	ErrUnsupportedProtocolVersion = errors.New("unsupported protocol version")
	ErrUnsupportedSchemaVersion   = errors.New("unsupported schema version")
	ErrInvalidAddress              = errors.New("required address is zero")
	ErrInvalidHash                 = errors.New("required hash is zero")
	ErrInvalidUint256              = errors.New("value is not a valid uint256")
	ErrInvalidValidityWindow       = errors.New("invalid validity window")
)

func validateUint256(name string, value *big.Int) error {
	if value == nil || value.Sign() < 0 || value.BitLen() > 256 {
		return fmt.Errorf("%s: %w", name, ErrInvalidUint256)
	}
	return nil
}

func validateAddress(name string, value common.Address) error {
	if value == (common.Address{}) {
		return fmt.Errorf("%s: %w", name, ErrInvalidAddress)
	}
	return nil
}

func validateHash(name string, value common.Hash) error {
	if value == (common.Hash{}) {
		return fmt.Errorf("%s: %w", name, ErrInvalidHash)
	}
	return nil
}

func validateWindow(validAfter, validUntil uint64) error {
	if validUntil == 0 || validAfter > validUntil {
		return ErrInvalidValidityWindow
	}
	return nil
}

// ValidatePolicyEnvelope validates protocol-level policy-envelope invariants.
func ValidatePolicyEnvelope(policy PolicyEnvelope) error {
	if policy.ProtocolVersion != CurrentProtocolVersion {
		return ErrUnsupportedProtocolVersion
	}
	if policy.SchemaVersion != CurrentPolicySchemaVersion {
		return ErrUnsupportedSchemaVersion
	}
	if err := validateHash("policyId", policy.PolicyID); err != nil {
		return err
	}
	if err := validateAddress("owner", policy.Owner); err != nil {
		return err
	}
	if err := validateAddress("account", policy.Account); err != nil {
		return err
	}
	if policy.PolicyVersion == 0 {
		return errors.New("policyVersion must be greater than zero")
	}
	if err := validateWindow(policy.ValidAfter, policy.ValidUntil); err != nil {
		return err
	}
	if err := validateHash("chainScopeHash", policy.ChainScopeHash); err != nil {
		return err
	}
	if err := validateHash("rulesHash", policy.RulesHash); err != nil {
		return err
	}
	if err := validateHash("metadataHash", policy.MetadataHash); err != nil {
		return err
	}
	return nil
}

// ValidateTransactionIntent validates protocol-level intent invariants.
func ValidateTransactionIntent(intent TransactionIntent) error {
	if intent.ProtocolVersion != CurrentProtocolVersion {
		return ErrUnsupportedProtocolVersion
	}
	if err := validateUint256("chainId", intent.ChainID); err != nil {
		return err
	}
	if intent.ChainID.Sign() == 0 {
		return errors.New("chainId must be greater than zero")
	}
	if err := validateAddress("executor", intent.Executor); err != nil {
		return err
	}
	if err := validateAddress("account", intent.Account); err != nil {
		return err
	}
	if err := validateAddress("agent", intent.Agent); err != nil {
		return err
	}
	if err := validateAddress("target", intent.Target); err != nil {
		return err
	}
	if err := validateUint256("value", intent.Value); err != nil {
		return err
	}
	return validateWindow(intent.ValidAfter, intent.ValidUntil)
}

// ValidateEvaluationRequest validates protocol-level request invariants.
func ValidateEvaluationRequest(request EvaluationRequest) error {
	if request.ProtocolVersion != CurrentProtocolVersion {
		return ErrUnsupportedProtocolVersion
	}
	if err := validateHash("requestId", request.RequestID); err != nil {
		return err
	}
	if err := validateHash("policyId", request.PolicyID); err != nil {
		return err
	}
	if err := validateHash("policyCommitment", request.PolicyCommitment); err != nil {
		return err
	}
	if request.PolicyVersion == 0 {
		return errors.New("policyVersion must be greater than zero")
	}
	if err := validateHash("intentHash", request.IntentHash); err != nil {
		return err
	}
	if request.RequestedAt == 0 {
		return errors.New("requestedAt must be greater than zero")
	}
	return nil
}

// ValidateFirewallDecision validates protocol-level decision invariants.
func ValidateFirewallDecision(decision FirewallDecision) error {
	if decision.ProtocolVersion != CurrentProtocolVersion {
		return ErrUnsupportedProtocolVersion
	}
	if decision.DecisionVersion != CurrentDecisionVersion {
		return ErrUnsupportedSchemaVersion
	}
	if err := validateHash("requestId", decision.RequestID); err != nil {
		return err
	}
	if err := validateHash("intentHash", decision.IntentHash); err != nil {
		return err
	}
	if err := validateHash("policyId", decision.PolicyID); err != nil {
		return err
	}
	if err := validateHash("policyCommitment", decision.PolicyCommitment); err != nil {
		return err
	}
	if decision.PolicyVersion == 0 {
		return errors.New("policyVersion must be greater than zero")
	}
	if err := validateUint256("chainId", decision.ChainID); err != nil {
		return err
	}
	if decision.ChainID.Sign() == 0 {
		return errors.New("chainId must be greater than zero")
	}
	if err := validateAddress("executor", decision.Executor); err != nil {
		return err
	}
	if err := validateAddress("account", decision.Account); err != nil {
		return err
	}
	if err := validateAddress("agent", decision.Agent); err != nil {
		return err
	}
	if err := validateWindow(decision.ValidAfter, decision.ValidUntil); err != nil {
		return err
	}
	if decision.SimulationBlockNumber == 0 {
		return errors.New("simulationBlockNumber must be greater than zero")
	}
	if err := validateHash("simulationBlockHash", decision.SimulationBlockHash); err != nil {
		return err
	}
	if err := validateHash("simulationHash", decision.SimulationHash); err != nil {
		return err
	}
	if decision.RiskScore > MaximumRiskScore {
		return fmt.Errorf("riskScore exceeds %d", MaximumRiskScore)
	}
	if err := validateUint256("riskFlags", decision.RiskFlags); err != nil {
		return err
	}
	return nil
}
EOF

  cat > "$PROJECT_ROOT/go/pkg/protocol/hashing.go" <<'EOF'
package protocol

import (
	"fmt"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
)

const (
	policyTypeString   = "SentinelPolicy(uint16 protocolVersion,uint16 schemaVersion,bytes32 policyId,address owner,address account,uint64 policyVersion,uint64 validAfter,uint64 validUntil,bytes32 chainScopeHash,bytes32 rulesHash,bytes32 metadataHash)"
	intentTypeString   = "SentinelTransactionIntent(uint16 protocolVersion,uint256 chainId,address executor,address account,address agent,address target,uint256 value,bytes32 calldataHash,uint64 nonce,uint64 validAfter,uint64 validUntil)"
	requestTypeString  = "SentinelEvaluationRequest(uint16 protocolVersion,bytes32 requestId,bytes32 policyId,bytes32 policyCommitment,uint64 policyVersion,bytes32 intentHash,uint64 requestedAt)"
	decisionTypeString = "SentinelFirewallDecision(uint16 protocolVersion,uint16 decisionVersion,bytes32 requestId,bytes32 intentHash,bytes32 policyId,bytes32 policyCommitment,uint64 policyVersion,uint256 chainId,address executor,address account,address agent,uint64 nonce,uint64 validAfter,uint64 validUntil,uint64 simulationBlockNumber,bytes32 simulationBlockHash,bytes32 simulationHash,bool approved,uint8 riskScore,uint256 riskFlags)"
)

var (
	policyTypeHash   = crypto.Keccak256Hash([]byte(policyTypeString))
	intentTypeHash   = crypto.Keccak256Hash([]byte(intentTypeString))
	requestTypeHash  = crypto.Keccak256Hash([]byte(requestTypeString))
	decisionTypeHash = crypto.Keccak256Hash([]byte(decisionTypeString))

	abiBytes32 = mustABIType("bytes32")
	abiUint16  = mustABIType("uint16")
	abiUint64  = mustABIType("uint64")
	abiUint8   = mustABIType("uint8")
	abiUint256 = mustABIType("uint256")
	abiAddress = mustABIType("address")
	abiBool    = mustABIType("bool")

	policyArguments = abi.Arguments{
		{Type: abiBytes32},
		{Type: abiUint16},
		{Type: abiUint16},
		{Type: abiBytes32},
		{Type: abiAddress},
		{Type: abiAddress},
		{Type: abiUint64},
		{Type: abiUint64},
		{Type: abiUint64},
		{Type: abiBytes32},
		{Type: abiBytes32},
		{Type: abiBytes32},
	}

	intentArguments = abi.Arguments{
		{Type: abiBytes32},
		{Type: abiUint16},
		{Type: abiUint256},
		{Type: abiAddress},
		{Type: abiAddress},
		{Type: abiAddress},
		{Type: abiAddress},
		{Type: abiUint256},
		{Type: abiBytes32},
		{Type: abiUint64},
		{Type: abiUint64},
		{Type: abiUint64},
	}

	requestArguments = abi.Arguments{
		{Type: abiBytes32},
		{Type: abiUint16},
		{Type: abiBytes32},
		{Type: abiBytes32},
		{Type: abiBytes32},
		{Type: abiUint64},
		{Type: abiBytes32},
		{Type: abiUint64},
	}

	decisionArguments = abi.Arguments{
		{Type: abiBytes32},
		{Type: abiUint16},
		{Type: abiUint16},
		{Type: abiBytes32},
		{Type: abiBytes32},
		{Type: abiBytes32},
		{Type: abiBytes32},
		{Type: abiUint64},
		{Type: abiUint256},
		{Type: abiAddress},
		{Type: abiAddress},
		{Type: abiAddress},
		{Type: abiUint64},
		{Type: abiUint64},
		{Type: abiUint64},
		{Type: abiUint64},
		{Type: abiBytes32},
		{Type: abiBytes32},
		{Type: abiBool},
		{Type: abiUint8},
		{Type: abiUint256},
	}
)

func mustABIType(name string) abi.Type {
	value, err := abi.NewType(name, "", nil)
	if err != nil {
		panic(fmt.Sprintf("create ABI type %q: %v", name, err))
	}
	return value
}

func hashPacked(arguments abi.Arguments, values ...any) (common.Hash, error) {
	encoded, err := arguments.Pack(values...)
	if err != nil {
		return common.Hash{}, fmt.Errorf("ABI-pack canonical protocol value: %w", err)
	}
	return crypto.Keccak256Hash(encoded), nil
}

// PolicyTypeHash returns the canonical SentinelPolicy type hash.
func PolicyTypeHash() common.Hash {
	return policyTypeHash
}

// TransactionIntentTypeHash returns the canonical intent type hash.
func TransactionIntentTypeHash() common.Hash {
	return intentTypeHash
}

// EvaluationRequestTypeHash returns the canonical request type hash.
func EvaluationRequestTypeHash() common.Hash {
	return requestTypeHash
}

// FirewallDecisionTypeHash returns the canonical decision type hash.
func FirewallDecisionTypeHash() common.Hash {
	return decisionTypeHash
}

// CalldataHash returns Keccak-256 over raw EVM calldata.
func CalldataHash(data []byte) common.Hash {
	return crypto.Keccak256Hash(data)
}

// HashPolicyEnvelope returns the canonical Solidity-compatible policy commitment.
func HashPolicyEnvelope(policy PolicyEnvelope) (common.Hash, error) {
	if err := ValidatePolicyEnvelope(policy); err != nil {
		return common.Hash{}, err
	}
	return hashPacked(
		policyArguments,
		policyTypeHash,
		policy.ProtocolVersion,
		policy.SchemaVersion,
		policy.PolicyID,
		policy.Owner,
		policy.Account,
		policy.PolicyVersion,
		policy.ValidAfter,
		policy.ValidUntil,
		policy.ChainScopeHash,
		policy.RulesHash,
		policy.MetadataHash,
	)
}

// HashTransactionIntent returns the canonical Solidity-compatible intent hash.
func HashTransactionIntent(intent TransactionIntent) (common.Hash, error) {
	if err := ValidateTransactionIntent(intent); err != nil {
		return common.Hash{}, err
	}
	return hashPacked(
		intentArguments,
		intentTypeHash,
		intent.ProtocolVersion,
		intent.ChainID,
		intent.Executor,
		intent.Account,
		intent.Agent,
		intent.Target,
		intent.Value,
		CalldataHash(intent.Data),
		intent.Nonce,
		intent.ValidAfter,
		intent.ValidUntil,
	)
}

// HashEvaluationRequest returns the canonical Solidity-compatible request hash.
func HashEvaluationRequest(request EvaluationRequest) (common.Hash, error) {
	if err := ValidateEvaluationRequest(request); err != nil {
		return common.Hash{}, err
	}
	return hashPacked(
		requestArguments,
		requestTypeHash,
		request.ProtocolVersion,
		request.RequestID,
		request.PolicyID,
		request.PolicyCommitment,
		request.PolicyVersion,
		request.IntentHash,
		request.RequestedAt,
	)
}

// HashFirewallDecision returns the canonical Solidity-compatible decision hash.
func HashFirewallDecision(decision FirewallDecision) (common.Hash, error) {
	if err := ValidateFirewallDecision(decision); err != nil {
		return common.Hash{}, err
	}
	return hashPacked(
		decisionArguments,
		decisionTypeHash,
		decision.ProtocolVersion,
		decision.DecisionVersion,
		decision.RequestID,
		decision.IntentHash,
		decision.PolicyID,
		decision.PolicyCommitment,
		decision.PolicyVersion,
		decision.ChainID,
		decision.Executor,
		decision.Account,
		decision.Agent,
		decision.Nonce,
		decision.ValidAfter,
		decision.ValidUntil,
		decision.SimulationBlockNumber,
		decision.SimulationBlockHash,
		decision.SimulationHash,
		decision.Approved,
		decision.RiskScore,
		decision.RiskFlags,
	)
}
EOF
}

write_solidity_protocol_library() {
  mkdir -p "$PROJECT_ROOT/contracts/libraries"

  cat > "$PROJECT_ROOT/contracts/libraries/SentinelProtocol.sol" <<'EOF'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @title SentinelProtocol
/// @notice Versioned canonical structs and hashing for SentinelFCC.
/// @dev These are struct hashes, not final EIP-712 signing digests.
library SentinelProtocol {
    uint16 internal constant CURRENT_PROTOCOL_VERSION = 1;
    uint16 internal constant CURRENT_POLICY_SCHEMA_VERSION = 1;
    uint16 internal constant CURRENT_DECISION_VERSION = 1;

    bytes32 internal constant POLICY_TYPEHASH = keccak256(
        "SentinelPolicy(uint16 protocolVersion,uint16 schemaVersion,bytes32 policyId,address owner,address account,uint64 policyVersion,uint64 validAfter,uint64 validUntil,bytes32 chainScopeHash,bytes32 rulesHash,bytes32 metadataHash)"
    );

    bytes32 internal constant TRANSACTION_INTENT_TYPEHASH = keccak256(
        "SentinelTransactionIntent(uint16 protocolVersion,uint256 chainId,address executor,address account,address agent,address target,uint256 value,bytes32 calldataHash,uint64 nonce,uint64 validAfter,uint64 validUntil)"
    );

    bytes32 internal constant EVALUATION_REQUEST_TYPEHASH = keccak256(
        "SentinelEvaluationRequest(uint16 protocolVersion,bytes32 requestId,bytes32 policyId,bytes32 policyCommitment,uint64 policyVersion,bytes32 intentHash,uint64 requestedAt)"
    );

    bytes32 internal constant FIREWALL_DECISION_TYPEHASH = keccak256(
        "SentinelFirewallDecision(uint16 protocolVersion,uint16 decisionVersion,bytes32 requestId,bytes32 intentHash,bytes32 policyId,bytes32 policyCommitment,uint64 policyVersion,uint256 chainId,address executor,address account,address agent,uint64 nonce,uint64 validAfter,uint64 validUntil,uint64 simulationBlockNumber,bytes32 simulationBlockHash,bytes32 simulationHash,bool approved,uint8 riskScore,uint256 riskFlags)"
    );

    uint8 internal constant RISK_UNKNOWN_TARGET = 0;
    uint8 internal constant RISK_SELECTOR_NOT_ALLOWED = 1;
    uint8 internal constant RISK_UNLIMITED_APPROVAL = 2;
    uint8 internal constant RISK_APPROVAL_TOO_LARGE = 3;
    uint8 internal constant RISK_TRANSFER_TOO_LARGE = 4;
    uint8 internal constant RISK_RECIPIENT_NOT_ALLOWED = 5;
    uint8 internal constant RISK_SIMULATION_FAILED = 6;
    uint8 internal constant RISK_SIMULATION_STALE = 7;
    uint8 internal constant RISK_PROVIDER_DISAGREEMENT = 8;
    uint8 internal constant RISK_MALFORMED_CALLDATA = 9;
    uint8 internal constant RISK_UNSUPPORTED_OPERATION = 10;
    uint8 internal constant RISK_POLICY_MISSING = 11;
    uint8 internal constant RISK_POLICY_REVOKED = 12;
    uint8 internal constant RISK_AGENT_UNAUTHORIZED = 13;
    uint8 internal constant RISK_REQUEST_EXPIRED = 14;
    uint8 internal constant RISK_NONCE_REUSED = 15;
    uint8 internal constant RISK_CODE_HASH_MISMATCH = 16;
    uint8 internal constant RISK_NESTED_CALL_OPAQUE = 17;

    struct PolicyEnvelope {
        uint16 protocolVersion;
        uint16 schemaVersion;
        bytes32 policyId;
        address owner;
        address account;
        uint64 policyVersion;
        uint64 validAfter;
        uint64 validUntil;
        bytes32 chainScopeHash;
        bytes32 rulesHash;
        bytes32 metadataHash;
    }

    struct TransactionIntent {
        uint16 protocolVersion;
        uint256 chainId;
        address executor;
        address account;
        address agent;
        address target;
        uint256 value;
        bytes data;
        uint64 nonce;
        uint64 validAfter;
        uint64 validUntil;
    }

    struct EvaluationRequest {
        uint16 protocolVersion;
        bytes32 requestId;
        bytes32 policyId;
        bytes32 policyCommitment;
        uint64 policyVersion;
        bytes32 intentHash;
        uint64 requestedAt;
    }

    struct FirewallDecision {
        uint16 protocolVersion;
        uint16 decisionVersion;
        bytes32 requestId;
        bytes32 intentHash;
        bytes32 policyId;
        bytes32 policyCommitment;
        uint64 policyVersion;
        uint256 chainId;
        address executor;
        address account;
        address agent;
        uint64 nonce;
        uint64 validAfter;
        uint64 validUntil;
        uint64 simulationBlockNumber;
        bytes32 simulationBlockHash;
        bytes32 simulationHash;
        bool approved;
        uint8 riskScore;
        uint256 riskFlags;
    }

    function policyTypeHash() internal pure returns (bytes32) {
        return POLICY_TYPEHASH;
    }

    function transactionIntentTypeHash() internal pure returns (bytes32) {
        return TRANSACTION_INTENT_TYPEHASH;
    }

    function evaluationRequestTypeHash() internal pure returns (bytes32) {
        return EVALUATION_REQUEST_TYPEHASH;
    }

    function firewallDecisionTypeHash() internal pure returns (bytes32) {
        return FIREWALL_DECISION_TYPEHASH;
    }

    function riskMask(uint8 flag) internal pure returns (uint256) {
        require(flag <= RISK_NESTED_CALL_OPAQUE, "unknown risk flag");
        return uint256(1) << flag;
    }

    function hashPolicyEnvelope(PolicyEnvelope memory policy) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                POLICY_TYPEHASH,
                policy.protocolVersion,
                policy.schemaVersion,
                policy.policyId,
                policy.owner,
                policy.account,
                policy.policyVersion,
                policy.validAfter,
                policy.validUntil,
                policy.chainScopeHash,
                policy.rulesHash,
                policy.metadataHash
            )
        );
    }

    function calldataHash(bytes memory data) internal pure returns (bytes32) {
        return keccak256(data);
    }

    function hashTransactionIntent(TransactionIntent memory intent) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                TRANSACTION_INTENT_TYPEHASH,
                intent.protocolVersion,
                intent.chainId,
                intent.executor,
                intent.account,
                intent.agent,
                intent.target,
                intent.value,
                calldataHash(intent.data),
                intent.nonce,
                intent.validAfter,
                intent.validUntil
            )
        );
    }

    function hashEvaluationRequest(EvaluationRequest memory request) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                EVALUATION_REQUEST_TYPEHASH,
                request.protocolVersion,
                request.requestId,
                request.policyId,
                request.policyCommitment,
                request.policyVersion,
                request.intentHash,
                request.requestedAt
            )
        );
    }

    function hashFirewallDecision(FirewallDecision memory decision) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                FIREWALL_DECISION_TYPEHASH,
                decision.protocolVersion,
                decision.decisionVersion,
                decision.requestId,
                decision.intentHash,
                decision.policyId,
                decision.policyCommitment,
                decision.policyVersion,
                decision.chainId,
                decision.executor,
                decision.account,
                decision.agent,
                decision.nonce,
                decision.validAfter,
                decision.validUntil,
                decision.simulationBlockNumber,
                decision.simulationBlockHash,
                decision.simulationHash,
                decision.approved,
                decision.riskScore,
                decision.riskFlags
            )
        );
    }
}
EOF
}

write_vector_generator_and_go_tests() {
  mkdir -p \
    "$PROJECT_ROOT/go/internal/protocolvectors" \
    "$PROJECT_ROOT/go/cmd/protocol-vectors" \
    "$PROJECT_ROOT/testdata/protocol"

  cat > "$PROJECT_ROOT/go/internal/protocolvectors/vectors.go" <<'EOF'
package protocolvectors

import (
	"encoding/hex"
	"fmt"
	"math/big"

	"github.com/ethereum/go-ethereum/common"

	"extension-scaffold/pkg/protocol"
)

// Vector is the committed, language-neutral Sentinel protocol test vector.
type Vector struct {
	Version    uint16     `json:"version"`
	TypeHashes TypeHashes `json:"typeHashes"`
	Hashes     Hashes     `json:"hashes"`
}

// TypeHashes contains canonical type-string hashes.
type TypeHashes struct {
	Policy            string `json:"policy"`
	TransactionIntent string `json:"transactionIntent"`
	EvaluationRequest string `json:"evaluationRequest"`
	FirewallDecision  string `json:"firewallDecision"`
}

// Hashes contains canonical hashes for the fixed v1 fixture.
type Hashes struct {
	PolicyCommitment string `json:"policyCommitment"`
	CalldataHash     string `json:"calldataHash"`
	IntentHash       string `json:"intentHash"`
	RequestHash      string `json:"requestHash"`
	DecisionHash     string `json:"decisionHash"`
}

// Fixture contains the canonical values shared by Go and Solidity tests.
type Fixture struct {
	Policy   protocol.PolicyEnvelope
	Intent   protocol.TransactionIntent
	Request  protocol.EvaluationRequest
	Decision protocol.FirewallDecision
}

// BuildFixture returns the fixed v1 cross-language fixture.
func BuildFixture() (Fixture, error) {
	data, err := hex.DecodeString(
		"095ea7b3" +
			"0000000000000000000000006666666666666666666666666666666666666666" +
			"0000000000000000000000000000000000000000000000000000000005f5e100",
	)
	if err != nil {
		return Fixture{}, fmt.Errorf("decode fixture calldata: %w", err)
	}

	policy := protocol.PolicyEnvelope{
		ProtocolVersion: protocol.CurrentProtocolVersion,
		SchemaVersion:   protocol.CurrentPolicySchemaVersion,
		PolicyID:        common.HexToHash("0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
		Owner:           common.HexToAddress("0x1111111111111111111111111111111111111111"),
		Account:         common.HexToAddress("0x2222222222222222222222222222222222222222"),
		PolicyVersion:   7,
		ValidAfter:      1_800_000_000,
		ValidUntil:      1_800_086_400,
		ChainScopeHash:  common.HexToHash("0xdddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"),
		RulesHash:       common.HexToHash("0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
		MetadataHash:    common.HexToHash("0xcccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"),
	}

	policyCommitment, err := protocol.HashPolicyEnvelope(policy)
	if err != nil {
		return Fixture{}, fmt.Errorf("hash policy fixture: %w", err)
	}

	intent := protocol.TransactionIntent{
		ProtocolVersion: protocol.CurrentProtocolVersion,
		ChainID:         big.NewInt(114),
		Executor:        common.HexToAddress("0x4444444444444444444444444444444444444444"),
		Account:         policy.Account,
		Agent:           common.HexToAddress("0x3333333333333333333333333333333333333333"),
		Target:          common.HexToAddress("0x5555555555555555555555555555555555555555"),
		Value:           big.NewInt(0),
		Data:            data,
		Nonce:           42,
		ValidAfter:      1_800_000_100,
		ValidUntil:      1_800_000_700,
	}

	intentHash, err := protocol.HashTransactionIntent(intent)
	if err != nil {
		return Fixture{}, fmt.Errorf("hash intent fixture: %w", err)
	}

	request := protocol.EvaluationRequest{
		ProtocolVersion:  protocol.CurrentProtocolVersion,
		RequestID:        common.HexToHash("0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"),
		PolicyID:         policy.PolicyID,
		PolicyCommitment: policyCommitment,
		PolicyVersion:    policy.PolicyVersion,
		IntentHash:       intentHash,
		RequestedAt:      1_800_000_120,
	}

	riskFlags, err := protocol.CombineRiskFlags(
		protocol.RiskUnknownTarget,
		protocol.RiskUnlimitedApproval,
	)
	if err != nil {
		return Fixture{}, fmt.Errorf("build risk mask: %w", err)
	}

	decision := protocol.FirewallDecision{
		ProtocolVersion:       protocol.CurrentProtocolVersion,
		DecisionVersion:       protocol.CurrentDecisionVersion,
		RequestID:             request.RequestID,
		IntentHash:            intentHash,
		PolicyID:              policy.PolicyID,
		PolicyCommitment:      policyCommitment,
		PolicyVersion:         policy.PolicyVersion,
		ChainID:               new(big.Int).Set(intent.ChainID),
		Executor:              intent.Executor,
		Account:               intent.Account,
		Agent:                 intent.Agent,
		Nonce:                 intent.Nonce,
		ValidAfter:            intent.ValidAfter,
		ValidUntil:            intent.ValidUntil,
		SimulationBlockNumber: 12_345_678,
		SimulationBlockHash:   common.HexToHash("0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"),
		SimulationHash:        common.HexToHash("0x9999999999999999999999999999999999999999999999999999999999999999"),
		Approved:              false,
		RiskScore:             98,
		RiskFlags:             riskFlags,
	}

	return Fixture{
		Policy:   policy,
		Intent:   intent,
		Request:  request,
		Decision: decision,
	}, nil
}

// Build returns the canonical v1 vector.
func Build() (Vector, error) {
	fixture, err := BuildFixture()
	if err != nil {
		return Vector{}, err
	}

	policyHash, err := protocol.HashPolicyEnvelope(fixture.Policy)
	if err != nil {
		return Vector{}, err
	}
	intentHash, err := protocol.HashTransactionIntent(fixture.Intent)
	if err != nil {
		return Vector{}, err
	}
	requestHash, err := protocol.HashEvaluationRequest(fixture.Request)
	if err != nil {
		return Vector{}, err
	}
	decisionHash, err := protocol.HashFirewallDecision(fixture.Decision)
	if err != nil {
		return Vector{}, err
	}

	return Vector{
		Version: protocol.CurrentProtocolVersion,
		TypeHashes: TypeHashes{
			Policy:            protocol.PolicyTypeHash().Hex(),
			TransactionIntent: protocol.TransactionIntentTypeHash().Hex(),
			EvaluationRequest: protocol.EvaluationRequestTypeHash().Hex(),
			FirewallDecision:  protocol.FirewallDecisionTypeHash().Hex(),
		},
		Hashes: Hashes{
			PolicyCommitment: policyHash.Hex(),
			CalldataHash:     protocol.CalldataHash(fixture.Intent.Data).Hex(),
			IntentHash:       intentHash.Hex(),
			RequestHash:      requestHash.Hex(),
			DecisionHash:     decisionHash.Hex(),
		},
	}, nil
}
EOF

  cat > "$PROJECT_ROOT/go/cmd/protocol-vectors/main.go" <<'EOF'
package main

import (
	"encoding/json"
	"fmt"
	"os"

	"extension-scaffold/internal/protocolvectors"
)

func main() {
	vector, err := protocolvectors.Build()
	if err != nil {
		fmt.Fprintf(os.Stderr, "build protocol vector: %v\n", err)
		os.Exit(1)
	}

	encoder := json.NewEncoder(os.Stdout)
	encoder.SetEscapeHTML(false)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(vector); err != nil {
		fmt.Fprintf(os.Stderr, "encode protocol vector: %v\n", err)
		os.Exit(1)
	}
}
EOF

  cat > "$PROJECT_ROOT/go/pkg/protocol/hashing_test.go" <<'EOF'
package protocol_test

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"testing"

	"extension-scaffold/internal/protocolvectors"
	"extension-scaffold/pkg/protocol"
)

func committedVectorPath(t *testing.T) string {
	t.Helper()
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("resolve test source path")
	}
	return filepath.Clean(filepath.Join(filepath.Dir(file), "../../../testdata/protocol/v1.json"))
}

func TestCommittedVectorMatchesCanonicalGenerator(t *testing.T) {
	expectedBytes, err := os.ReadFile(committedVectorPath(t))
	if err != nil {
		t.Fatalf("read committed vector: %v", err)
	}

	var expected protocolvectors.Vector
	if err := json.Unmarshal(expectedBytes, &expected); err != nil {
		t.Fatalf("decode committed vector: %v", err)
	}

	actual, err := protocolvectors.Build()
	if err != nil {
		t.Fatalf("build vector: %v", err)
	}

	if !reflect.DeepEqual(expected, actual) {
		t.Fatalf("committed vector differs from generator\nexpected: %#v\nactual: %#v", expected, actual)
	}
}

func TestIntentHashChangesWhenCalldataChanges(t *testing.T) {
	fixture, err := protocolvectors.BuildFixture()
	if err != nil {
		t.Fatal(err)
	}

	original, err := protocol.HashTransactionIntent(fixture.Intent)
	if err != nil {
		t.Fatal(err)
	}

	mutated := fixture.Intent
	mutated.Data = bytes.Clone(fixture.Intent.Data)
	mutated.Data[len(mutated.Data)-1] ^= 0x01

	changed, err := protocol.HashTransactionIntent(mutated)
	if err != nil {
		t.Fatal(err)
	}

	if original == changed {
		t.Fatal("changing one calldata byte did not change the intent hash")
	}
}

func TestIntentHashChangesWhenExecutionScopeChanges(t *testing.T) {
	fixture, err := protocolvectors.BuildFixture()
	if err != nil {
		t.Fatal(err)
	}

	original, err := protocol.HashTransactionIntent(fixture.Intent)
	if err != nil {
		t.Fatal(err)
	}

	mutated := fixture.Intent
	mutated.Nonce++

	changed, err := protocol.HashTransactionIntent(mutated)
	if err != nil {
		t.Fatal(err)
	}

	if original == changed {
		t.Fatal("changing nonce did not change the intent hash")
	}
}
EOF

  cat > "$PROJECT_ROOT/go/pkg/protocol/validation_test.go" <<'EOF'
package protocol_test

import (
	"math/big"
	"testing"

	"extension-scaffold/internal/protocolvectors"
	"extension-scaffold/pkg/protocol"
)

func TestGoldenFixtureValidates(t *testing.T) {
	fixture, err := protocolvectors.BuildFixture()
	if err != nil {
		t.Fatal(err)
	}

	if err := protocol.ValidatePolicyEnvelope(fixture.Policy); err != nil {
		t.Fatalf("policy validation failed: %v", err)
	}
	if err := protocol.ValidateTransactionIntent(fixture.Intent); err != nil {
		t.Fatalf("intent validation failed: %v", err)
	}
	if err := protocol.ValidateEvaluationRequest(fixture.Request); err != nil {
		t.Fatalf("request validation failed: %v", err)
	}
	if err := protocol.ValidateFirewallDecision(fixture.Decision); err != nil {
		t.Fatalf("decision validation failed: %v", err)
	}
}

func TestUint256OverflowRejected(t *testing.T) {
	fixture, err := protocolvectors.BuildFixture()
	if err != nil {
		t.Fatal(err)
	}

	fixture.Intent.Value = new(big.Int).Lsh(big.NewInt(1), 256)
	if err := protocol.ValidateTransactionIntent(fixture.Intent); err == nil {
		t.Fatal("expected uint256 overflow to be rejected")
	}
}

func TestRiskFlagMask(t *testing.T) {
	mask, err := protocol.CombineRiskFlags(
		protocol.RiskUnknownTarget,
		protocol.RiskUnlimitedApproval,
	)
	if err != nil {
		t.Fatal(err)
	}

	if !protocol.HasRiskFlag(mask, protocol.RiskUnknownTarget) {
		t.Fatal("unknown-target flag missing")
	}
	if !protocol.HasRiskFlag(mask, protocol.RiskUnlimitedApproval) {
		t.Fatal("unlimited-approval flag missing")
	}
	if protocol.HasRiskFlag(mask, protocol.RiskSimulationFailed) {
		t.Fatal("unexpected simulation-failed flag")
	}
}
EOF
}

generate_committed_vector() {
  local tmp_vector
  tmp_vector="$(mktemp)"

  (
    cd "$PROJECT_ROOT/go"
    go run ./cmd/protocol-vectors > "$tmp_vector"
  )

  python3 - "$tmp_vector" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as handle:
    data = json.load(handle)

required = {"version", "typeHashes", "hashes"}
missing = required - data.keys()
if missing:
    raise SystemExit(f"generated vector is missing keys: {sorted(missing)}")

for section in ("typeHashes", "hashes"):
    for key, value in data[section].items():
        if not isinstance(value, str) or not value.startswith("0x") or len(value) != 66:
            raise SystemExit(f"invalid {section}.{key}: {value!r}")
PY

  mv "$tmp_vector" "$PROJECT_ROOT/testdata/protocol/v1.json"
  ok "Generated committed Go protocol vector."
}

generate_solidity_cross_language_test() {
  mkdir -p "$PROJECT_ROOT/test"

  python3 - "$PROJECT_ROOT/testdata/protocol/v1.json" "$PROJECT_ROOT/test/SentinelProtocol.t.sol" <<'PY'
import json
from pathlib import Path
import sys

vector_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])
vector = json.loads(vector_path.read_text(encoding="utf-8"))

t = vector["typeHashes"]
h = vector["hashes"]

source = f'''// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {{SentinelProtocol}} from "../contracts/libraries/SentinelProtocol.sol";

contract SentinelProtocolHashingTest {{
    bytes32 private constant EXPECTED_POLICY_TYPEHASH = {t["policy"]};
    bytes32 private constant EXPECTED_INTENT_TYPEHASH = {t["transactionIntent"]};
    bytes32 private constant EXPECTED_REQUEST_TYPEHASH = {t["evaluationRequest"]};
    bytes32 private constant EXPECTED_DECISION_TYPEHASH = {t["firewallDecision"]};

    bytes32 private constant EXPECTED_POLICY_COMMITMENT = {h["policyCommitment"]};
    bytes32 private constant EXPECTED_CALLDATA_HASH = {h["calldataHash"]};
    bytes32 private constant EXPECTED_INTENT_HASH = {h["intentHash"]};
    bytes32 private constant EXPECTED_REQUEST_HASH = {h["requestHash"]};
    bytes32 private constant EXPECTED_DECISION_HASH = {h["decisionHash"]};

    function testTypeHashesMatchGoVector() public pure {{
        require(SentinelProtocol.policyTypeHash() == EXPECTED_POLICY_TYPEHASH, "policy typehash");
        require(SentinelProtocol.transactionIntentTypeHash() == EXPECTED_INTENT_TYPEHASH, "intent typehash");
        require(SentinelProtocol.evaluationRequestTypeHash() == EXPECTED_REQUEST_TYPEHASH, "request typehash");
        require(SentinelProtocol.firewallDecisionTypeHash() == EXPECTED_DECISION_TYPEHASH, "decision typehash");
    }}

    function testPolicyCommitmentMatchesGoVector() public pure {{
        SentinelProtocol.PolicyEnvelope memory policy = _policy();
        require(SentinelProtocol.hashPolicyEnvelope(policy) == EXPECTED_POLICY_COMMITMENT, "policy hash");
    }}

    function testIntentHashMatchesGoVector() public pure {{
        SentinelProtocol.TransactionIntent memory intent = _intent();
        require(SentinelProtocol.calldataHash(intent.data) == EXPECTED_CALLDATA_HASH, "calldata hash");
        require(SentinelProtocol.hashTransactionIntent(intent) == EXPECTED_INTENT_HASH, "intent hash");
    }}

    function testRequestHashMatchesGoVector() public pure {{
        SentinelProtocol.EvaluationRequest memory request = SentinelProtocol.EvaluationRequest({{
            protocolVersion: 1,
            requestId: 0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee,
            policyId: 0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa,
            policyCommitment: EXPECTED_POLICY_COMMITMENT,
            policyVersion: 7,
            intentHash: EXPECTED_INTENT_HASH,
            requestedAt: 1_800_000_120
        }});

        require(SentinelProtocol.hashEvaluationRequest(request) == EXPECTED_REQUEST_HASH, "request hash");
    }}

    function testDecisionHashMatchesGoVector() public pure {{
        uint256 riskFlags = SentinelProtocol.riskMask(0) | SentinelProtocol.riskMask(2);

        SentinelProtocol.FirewallDecision memory decision = SentinelProtocol.FirewallDecision({{
            protocolVersion: 1,
            decisionVersion: 1,
            requestId: 0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee,
            intentHash: EXPECTED_INTENT_HASH,
            policyId: 0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa,
            policyCommitment: EXPECTED_POLICY_COMMITMENT,
            policyVersion: 7,
            chainId: 114,
            executor: address(0x4444444444444444444444444444444444444444),
            account: address(0x2222222222222222222222222222222222222222),
            agent: address(0x3333333333333333333333333333333333333333),
            nonce: 42,
            validAfter: 1_800_000_100,
            validUntil: 1_800_000_700,
            simulationBlockNumber: 12_345_678,
            simulationBlockHash: 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff,
            simulationHash: 0x9999999999999999999999999999999999999999999999999999999999999999,
            approved: false,
            riskScore: 98,
            riskFlags: riskFlags
        }});

        require(SentinelProtocol.hashFirewallDecision(decision) == EXPECTED_DECISION_HASH, "decision hash");
    }}

    function testIntentMutationChangesHash() public pure {{
        SentinelProtocol.TransactionIntent memory intent = _intent();
        bytes32 originalHash = SentinelProtocol.hashTransactionIntent(intent);
        intent.nonce += 1;
        require(SentinelProtocol.hashTransactionIntent(intent) != originalHash, "nonce not bound");
    }}

    function _policy() private pure returns (SentinelProtocol.PolicyEnvelope memory) {{
        return SentinelProtocol.PolicyEnvelope({{
            protocolVersion: 1,
            schemaVersion: 1,
            policyId: 0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa,
            owner: address(0x1111111111111111111111111111111111111111),
            account: address(0x2222222222222222222222222222222222222222),
            policyVersion: 7,
            validAfter: 1_800_000_000,
            validUntil: 1_800_086_400,
            chainScopeHash: 0xdddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd,
            rulesHash: 0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb,
            metadataHash: 0xcccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
        }});
    }}

    function _intent() private pure returns (SentinelProtocol.TransactionIntent memory) {{
        return SentinelProtocol.TransactionIntent({{
            protocolVersion: 1,
            chainId: 114,
            executor: address(0x4444444444444444444444444444444444444444),
            account: address(0x2222222222222222222222222222222222222222),
            agent: address(0x3333333333333333333333333333333333333333),
            target: address(0x5555555555555555555555555555555555555555),
            value: 0,
            data: hex"095ea7b300000000000000000000000066666666666666666666666666666666666666660000000000000000000000000000000000000000000000000000000005f5e100",
            nonce: 42,
            validAfter: 1_800_000_100,
            validUntil: 1_800_000_700
        }});
    }}
}}
'''

output_path.write_text(source, encoding="utf-8")
PY

  ok "Generated Solidity cross-language hashing test."
}

write_vector_verification_script() {
  cat > "$PROJECT_ROOT/scripts/sentinel/check-protocol-vectors.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT="$(git rev-parse --show-toplevel)"
VECTOR="$ROOT/testdata/protocol/v1.json"
SOLIDITY_TEST="$ROOT/test/SentinelProtocol.t.sol"
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

python3 - "$VECTOR" "$SOLIDITY_TEST" <<'PY'
import json
from pathlib import Path
import re
import sys

vector = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
source = Path(sys.argv[2]).read_text(encoding="utf-8")

expected = {
    "EXPECTED_POLICY_TYPEHASH": vector["typeHashes"]["policy"],
    "EXPECTED_INTENT_TYPEHASH": vector["typeHashes"]["transactionIntent"],
    "EXPECTED_REQUEST_TYPEHASH": vector["typeHashes"]["evaluationRequest"],
    "EXPECTED_DECISION_TYPEHASH": vector["typeHashes"]["firewallDecision"],
    "EXPECTED_POLICY_COMMITMENT": vector["hashes"]["policyCommitment"],
    "EXPECTED_CALLDATA_HASH": vector["hashes"]["calldataHash"],
    "EXPECTED_INTENT_HASH": vector["hashes"]["intentHash"],
    "EXPECTED_REQUEST_HASH": vector["hashes"]["requestHash"],
    "EXPECTED_DECISION_HASH": vector["hashes"]["decisionHash"],
}

for name, value in expected.items():
    pattern = rf"bytes32 private constant {name} = (0x[0-9a-f]{{64}});"
    match = re.search(pattern, source)
    if match is None:
        raise SystemExit(f"missing Solidity vector constant: {name}")
    if match.group(1) != value:
        raise SystemExit(
            f"Solidity vector mismatch for {name}: "
            f"{match.group(1)} != {value}"
        )
PY

printf '[protocol-vectors] Go JSON and Solidity constants are synchronized\n'
EOF

  chmod 0755 "$PROJECT_ROOT/scripts/sentinel/check-protocol-vectors.sh"

  python3 - "$PROJECT_ROOT/scripts/sentinel/verify.sh" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

vector_block = '''info "Checking canonical protocol vectors"
./scripts/sentinel/check-protocol-vectors.sh

'''
vector_anchor = 'info "Checking Solidity formatting"\n'

if vector_block not in text:
    if vector_anchor not in text:
        raise SystemExit("verify.sh is missing the Solidity formatting anchor")
    text = text.replace(vector_anchor, vector_block + vector_anchor, 1)

test_block = '''info "Running Solidity protocol tests"
forge test

'''
test_anchor = 'info "Running Go extension tests"\n'

if test_block not in text:
    if test_anchor not in text:
        raise SystemExit("verify.sh is missing the Go-test anchor")
    text = text.replace(test_anchor, test_block + test_anchor, 1)

path.write_text(text, encoding="utf-8")
PY
}

write_protocol_documentation() {
  cat > "$PROJECT_ROOT/docs/protocol-v1.md" <<'EOF'
# Sentinel Protocol v1

## Status

Protocol v1 defines canonical, cross-language hashes for policy envelopes,
transaction intents, evaluation requests, and firewall decisions. These hashes
are foundational commitments. They are not final signatures and are not yet
authorizations accepted by an executor.

## Encoding rules

Every struct hash is:

```text
keccak256(abi.encode(TYPEHASH, field_1, field_2, ...))
```

Rules:

- Integer widths in the type string are normative.
- ABI encoding pads every fixed value to a 32-byte word.
- Addresses are encoded as Solidity `address`.
- `uint256` values must be non-negative and at most 256 bits.
- Dynamic transaction calldata is represented by `keccak256(data)`.
- Field order is normative.
- A schema change requires a new version and new type string.
- JSON is an API representation only; it is never the signature preimage.

## Canonical type strings

```text
SentinelPolicy(uint16 protocolVersion,uint16 schemaVersion,bytes32 policyId,address owner,address account,uint64 policyVersion,uint64 validAfter,uint64 validUntil,bytes32 chainScopeHash,bytes32 rulesHash,bytes32 metadataHash)
```

```text
SentinelTransactionIntent(uint16 protocolVersion,uint256 chainId,address executor,address account,address agent,address target,uint256 value,bytes32 calldataHash,uint64 nonce,uint64 validAfter,uint64 validUntil)
```

```text
SentinelEvaluationRequest(uint16 protocolVersion,bytes32 requestId,bytes32 policyId,bytes32 policyCommitment,uint64 policyVersion,bytes32 intentHash,uint64 requestedAt)
```

```text
SentinelFirewallDecision(uint16 protocolVersion,uint16 decisionVersion,bytes32 requestId,bytes32 intentHash,bytes32 policyId,bytes32 policyCommitment,uint64 policyVersion,uint256 chainId,address executor,address account,address agent,uint64 nonce,uint64 validAfter,uint64 validUntil,uint64 simulationBlockNumber,bytes32 simulationBlockHash,bytes32 simulationHash,bool approved,uint8 riskScore,uint256 riskFlags)
```

## Security properties established

- Changing one calldata byte changes the intent hash.
- Chain, executor, protected account, agent, target, value, nonce, and validity
  window are bound to the intent.
- The request binds one request ID, policy version, policy commitment, and
  exact intent hash.
- The decision binds the simulation state and normalized simulation result.
- Risk flags have stable bit positions across Go and Solidity.
- Golden vectors prove Go and Solidity produce identical hashes.

## Not yet implemented

Protocol v1 does not yet include:

- EIP-712 domain separation and signature recovery;
- onchain nonce consumption;
- policy registration or revocation contracts;
- encrypted private-policy transport;
- TEE ActionResult verification;
- transaction execution.

Those are separate layers built on these canonical commitments.
EOF

  python3 - "$PROJECT_ROOT/README.md" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
entry = "- [Protocol v1 canonical encoding](docs/protocol-v1.md)\n"
anchor = "- [Protocol](docs/protocol.md)\n"

if entry not in text:
    if anchor not in text:
        raise SystemExit("README documentation anchor not found")
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

  info "Formatting Go and Solidity sources"
  gofmt -w \
    go/pkg/protocol \
    go/internal/protocolvectors \
    go/cmd/protocol-vectors

  forge fmt

  info "Checking patch scripts and tracked whitespace"
  bash -n "$ARCHIVE_RELATIVE_PATH"
  bash -n scripts/sentinel/check-protocol-vectors.sh
  shellcheck scripts/sentinel/*.sh
  git diff --check

  info "Running the complete Sentinel verification suite"
  ./scripts/sentinel/verify.sh

  ok "All protocol, cross-language, Solidity, Go, and scaffold checks passed."
}

verify_expected_change_set() {
  cd "$PROJECT_ROOT"

  python3 <<'PY'
import subprocess

allowed_prefixes = (
    "go/pkg/protocol/",
    "go/internal/protocolvectors/",
    "go/cmd/protocol-vectors/",
)
allowed_exact = {
    "contracts/libraries/SentinelProtocol.sol",
    "test/SentinelProtocol.t.sol",
    "testdata/protocol/v1.json",
    "scripts/sentinel/check-protocol-vectors.sh",
    "scripts/sentinel/verify.sh",
    "docs/protocol-v1.md",
    "README.md",
    "scripts/patches/004-protocol-v1-foundation.sh",
}

changed = subprocess.check_output(
    ["git", "status", "--porcelain=v1", "--untracked-files=all"],
    text=True,
).splitlines()

unexpected = []
for line in changed:
    path = line[3:]
    if path in allowed_exact or path.startswith(allowed_prefixes):
        continue
    unexpected.append(line)

if unexpected:
    raise SystemExit(
        "Unexpected files in Patch 004 change set:\n  "
        + "\n  ".join(unexpected)
    )
PY

  ok "Patch 004 changed only the intended protocol files."
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

  git add "$ARCHIVE_RELATIVE_PATH"
  git diff --cached --check
  git commit -m "chore(project): archive protocol foundation patch"

  [[ -z "$(git status --porcelain=v1)" ]] ||
    die "Working tree is not clean after Patch 004 commits."

  ok "Created four atomic Patch 004 commits."
}

push_feature_branch() {
  cd "$PROJECT_ROOT"
  git push -u origin "$FEATURE_BRANCH"

  printf '\n'
  ok "Patch 004 completed and pushed."
  printf 'Branch: %s\n' "$FEATURE_BRANCH"
  printf 'Head:   %s\n' "$(git rev-parse --short HEAD)"
  printf '\nCommits:\n'
  git log --oneline "origin/$BASE_BRANCH..HEAD"
  printf '\nOpen the pull request:\n'
  printf 'https://github.com/prateushsharma/sentinel-fcc/compare/%s...%s?expand=1\n' \
    "$BASE_BRANCH" "$FEATURE_BRANCH"
  printf '\nNext stage after review: Policy Registry and replay-safe Executor contracts.\n'
}

main() {
  require_command git
  require_command go
  require_command gofmt
  require_command forge
  require_command python3
  require_command shellcheck
  require_command diff

  validate_and_create_branch

  cd "$PROJECT_ROOT"
  write_go_protocol_sources
  write_solidity_protocol_library
  write_vector_generator_and_go_tests
  generate_committed_vector
  generate_solidity_cross_language_test
  write_vector_verification_script
  write_protocol_documentation
  archive_patch

  format_and_verify
  verify_expected_change_set
  commit_atomic_history
  push_feature_branch
}

main "$@"
