package extension

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
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
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		if err == nil {
			err = fmt.Errorf("multiple top-level JSON values")
		}
		return buildResult(
			action,
			dataFixed,
			nil,
			0,
			fmt.Errorf("decoding evaluation request: trailing data: %w", err),
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
