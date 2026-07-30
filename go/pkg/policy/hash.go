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
	Targets                     []TargetRule     `json:"targets"`
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
