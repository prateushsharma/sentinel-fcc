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
	if a.score > uint16(protocol.MaximumRiskScore) {
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
