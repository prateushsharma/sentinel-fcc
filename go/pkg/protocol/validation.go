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
	ErrInvalidAddress             = errors.New("required address is zero")
	ErrInvalidHash                = errors.New("required hash is zero")
	ErrInvalidUint256             = errors.New("value is not a valid uint256")
	ErrInvalidValidityWindow      = errors.New("invalid validity window")
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
