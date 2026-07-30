package extension

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"

	"extension-scaffold/internal/config"
	"extension-scaffold/internal/policyengine"
	"extension-scaffold/pkg/types"

	"github.com/flare-foundation/go-flare-common/pkg/tee/instruction"
	teetypes "github.com/flare-foundation/tee-node/pkg/types"
	teeutils "github.com/flare-foundation/tee-node/pkg/utils"
)

const simulationRequestTimeout = 20 * time.Second

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
	if e.simulatorErr != nil {
		return buildResult(
			action,
			dataFixed,
			nil,
			0,
			fmt.Errorf("simulation configuration: %w", e.simulatorErr),
		)
	}
	if e.simulator == nil {
		return buildResult(
			action,
			dataFixed,
			nil,
			0,
			fmt.Errorf("simulation service is not configured"),
		)
	}

	decryptContext, cancelDecrypt := context.WithTimeout(
		context.Background(),
		decryptRequestTimeout,
	)
	plaintext, err := e.decryptor.Decrypt(decryptContext, dataFixed.OriginalMessage)
	cancelDecrypt()
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

	simulationContext, cancelSimulation := context.WithTimeout(
		context.Background(),
		simulationRequestTimeout,
	)
	simulationResult, err := e.simulator.Simulate(simulationContext, intent)
	cancelSimulation()
	if err != nil {
		return buildResult(
			action,
			dataFixed,
			nil,
			0,
			fmt.Errorf("simulating intent: %w", err),
		)
	}

	result, err := policyengine.Evaluate(policyengine.Request{
		RequestID:      request.RequestID,
		EvaluationTime: dataFixed.Timestamp,
		PolicyEnvelope: request.PolicyEnvelope,
		PrivatePolicy:  request.PrivatePolicy,
		Intent:         intent,
		Simulation:     simulationResult.Snapshot,
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
