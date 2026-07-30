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

// SentinelEvaluationRequest is decrypted and decoded only inside the extension.
type SentinelEvaluationRequest struct {
	RequestID      common.Hash               `json:"requestId"`
	PolicyEnvelope protocol.PolicyEnvelope   `json:"policyEnvelope"`
	PrivatePolicy  policy.PrivatePolicy      `json:"privatePolicy"`
	Intent         SentinelTransactionIntent `json:"intent"`
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
	Nonce                 uint64         `json:"nonce"`
	ValidAfter            uint64         `json:"validAfter"`
	ValidUntil            uint64         `json:"validUntil"`
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
