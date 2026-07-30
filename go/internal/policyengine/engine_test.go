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
		SchemaVersion:   policy.CurrentSchemaVersion,
		PolicyID:        common.HexToHash("0x1111111111111111111111111111111111111111111111111111111111111111"),
		Owner:           common.HexToAddress("0x1111111111111111111111111111111111111111"),
		Account:         common.HexToAddress("0x2222222222222222222222222222222222222222"),
		Version:         1,
		ValidAfter:      100,
		ValidUntil:      10_000,
		AllowedChainIDs: []string{"114"},
		AuthorizedAgents: []common.Address{
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
