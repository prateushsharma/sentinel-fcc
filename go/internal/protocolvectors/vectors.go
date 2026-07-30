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
