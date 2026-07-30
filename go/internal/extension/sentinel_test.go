package extension

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"math/big"
	"net/http"
	"testing"

	"extension-scaffold/internal/config"
	"extension-scaffold/internal/policyengine"
	"extension-scaffold/internal/simulation"
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

type fixedSimulator struct {
	result simulation.Result
	err    error
}

func (simulator fixedSimulator) Simulate(
	_ context.Context,
	_ protocol.TransactionIntent,
) (simulation.Result, error) {
	return simulator.result, simulator.err
}

func TestProcessSentinelEvaluationApprovesQuorumSimulatedTransfer(t *testing.T) {
	request, snapshot := sentinelFixture(t)
	payload, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}

	extension := &Extension{
		decryptor: passthroughDecryptor{},
		simulator: fixedSimulator{
			result: simulation.Result{Snapshot: snapshot},
		},
	}
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
	if response.Decision.SimulationHash != snapshot.EffectsHash {
		t.Fatal("decision did not bind simulator effects hash")
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

func TestProcessSentinelFailsClosedWithoutSimulator(t *testing.T) {
	request, _ := sentinelFixture(t)
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
		t.Fatalf("expected routed handler HTTP 200, got %d", status)
	}

	var actionResult teetypes.ActionResult
	if err := json.Unmarshal(body, &actionResult); err != nil {
		t.Fatal(err)
	}
	if actionResult.Status != 0 {
		t.Fatal("evaluation succeeded without a simulator")
	}
}

func TestProcessSentinelRejectsClientSuppliedSimulation(t *testing.T) {
	request, _ := sentinelFixture(t)
	payload, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}

	var object map[string]any
	if err := json.Unmarshal(payload, &object); err != nil {
		t.Fatal(err)
	}
	object["simulation"] = map[string]any{"providerAgreement": true}
	payload, err = json.Marshal(object)
	if err != nil {
		t.Fatal(err)
	}

	extension := &Extension{
		decryptor: passthroughDecryptor{},
		simulator: fixedSimulator{},
	}
	action := buildTestAction(
		teeutils.ToHash(config.OPTypeSentinel),
		teeutils.ToHash(config.OPCommandEvaluate),
		payload,
	)

	_, body := extension.processAction(action)
	var actionResult teetypes.ActionResult
	if err := json.Unmarshal(body, &actionResult); err != nil {
		t.Fatal(err)
	}
	if actionResult.Status != 0 {
		t.Fatal("client-supplied simulation input was accepted")
	}
}

func sentinelFixture(t *testing.T) (
	types.SentinelEvaluationRequest,
	policyengine.SimulationSnapshot,
) {
	t.Helper()

	privatePolicy := policy.PrivatePolicy{
		SchemaVersion:   policy.CurrentSchemaVersion,
		PolicyID:        common.HexToHash("0x1111111111111111111111111111111111111111111111111111111111111111"),
		Owner:           common.HexToAddress("0x1111111111111111111111111111111111111111"),
		Account:         common.HexToAddress("0x2222222222222222222222222222222222222222"),
		Version:         1,
		ValidAfter:      0,
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

	request := types.SentinelEvaluationRequest{
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
	}

	snapshot := policyengine.SimulationSnapshot{
		IntentHash:          intentHash,
		BlockNumber:         900,
		BlockHash:           common.HexToHash("0xdddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"),
		ObservedBlockNumber: 901,
		EffectsHash:         common.HexToHash("0xcccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"),
		Success:             true,
		ProviderAgreement:   true,
		TargetCodeHash:      privatePolicy.Targets[0].CodeHash,
	}
	return request, snapshot
}
