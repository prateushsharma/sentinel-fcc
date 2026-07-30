package simulation

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math/big"
	"strings"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
)

const (
	effectsVersion = 1
	maxTraceDepth  = 128
	maxTraceFrames = 4096
	maxTraceLogs   = 8192
)

var (
	transferTopic = crypto.Keccak256Hash([]byte("Transfer(address,address,uint256)"))
	approvalTopic = crypto.Keccak256Hash([]byte("Approval(address,address,uint256)"))
)

type normalizer struct {
	effects NormalizedEffects
	frames  int
	logs    int
}

func normalizeTrace(frame callFrame) (NormalizedEffects, common.Hash, error) {
	normalized := normalizer{
		effects: NormalizedEffects{
			Version: effectsVersion,
			Success: frame.Error == "",
		},
	}

	if err := normalized.walk(frame, 0); err != nil {
		return NormalizedEffects{}, common.Hash{}, err
	}
	normalized.effects.ReturnDataHash = crypto.Keccak256Hash(frame.Output)

	encoded, err := json.Marshal(normalized.effects)
	if err != nil {
		return NormalizedEffects{}, common.Hash{}, fmt.Errorf("marshal normalized effects: %w", err)
	}
	return normalized.effects, crypto.Keccak256Hash(encoded), nil
}

func (normalizer *normalizer) walk(frame callFrame, depth uint16) error {
	if depth > maxTraceDepth {
		return fmt.Errorf("trace exceeds maximum depth %d", maxTraceDepth)
	}
	normalizer.frames++
	if normalizer.frames > maxTraceFrames {
		return fmt.Errorf("trace exceeds maximum frame count %d", maxTraceFrames)
	}

	value, err := parseHexQuantity(frame.Value)
	if err != nil {
		return fmt.Errorf("parse call value at depth %d: %w", depth, err)
	}
	selector := selectorHex(frame.Input)

	normalizer.effects.Calls = append(normalizer.effects.Calls, CallEffect{
		Depth:      depth,
		Type:       normalizedCallType(frame.Type),
		From:       frame.From,
		To:         frame.To,
		Value:      value.String(),
		Selector:   selector,
		InputHash:  crypto.Keccak256Hash(frame.Input),
		OutputHash: crypto.Keccak256Hash(frame.Output),
		Success:    frame.Error == "",
	})

	if value.Sign() > 0 && frame.From != (common.Address{}) && frame.To != (common.Address{}) {
		normalizer.effects.NativeTransfers = append(
			normalizer.effects.NativeTransfers,
			NativeTransfer{
				Depth: depth,
				From:  frame.From,
				To:    frame.To,
				Value: value.String(),
			},
		)
	}

	for _, log := range frame.Logs {
		if err := normalizer.addLog(log); err != nil {
			return err
		}
	}

	for _, child := range frame.Calls {
		if err := normalizer.walk(child, depth+1); err != nil {
			return err
		}
	}
	return nil
}

func (normalizer *normalizer) addLog(log traceLog) error {
	normalizer.logs++
	if normalizer.logs > maxTraceLogs {
		return fmt.Errorf("trace exceeds maximum log count %d", maxTraceLogs)
	}

	topics := append([]common.Hash(nil), log.Topics...)
	normalizer.effects.Logs = append(normalizer.effects.Logs, LogEffect{
		Emitter:  log.Address,
		Topics:   topics,
		DataHash: crypto.Keccak256Hash(log.Data),
	})

	if len(log.Topics) < 3 || len(log.Data) != 32 {
		return nil
	}

	amount := new(big.Int).SetBytes(log.Data).String()
	first := topicAddress(log.Topics[1])
	second := topicAddress(log.Topics[2])

	switch log.Topics[0] {
	case transferTopic:
		normalizer.effects.TokenTransfers = append(
			normalizer.effects.TokenTransfers,
			TokenTransfer{
				Token:  log.Address,
				From:   first,
				To:     second,
				Amount: amount,
			},
		)
	case approvalTopic:
		normalizer.effects.TokenApprovals = append(
			normalizer.effects.TokenApprovals,
			TokenApproval{
				Token:   log.Address,
				Owner:   first,
				Spender: second,
				Amount:  amount,
			},
		)
	}
	return nil
}

func parseHexQuantity(value string) (*big.Int, error) {
	if value == "" {
		return new(big.Int), nil
	}
	if len(value) < 3 || !strings.HasPrefix(value, "0x") {
		return nil, fmt.Errorf("invalid hex quantity %q", value)
	}
	parsed, ok := new(big.Int).SetString(value[2:], 16)
	if !ok || parsed.Sign() < 0 || parsed.BitLen() > 256 {
		return nil, fmt.Errorf("invalid uint256 quantity %q", value)
	}
	return parsed, nil
}

func selectorHex(input []byte) string {
	if len(input) < 4 {
		return "0x00000000"
	}
	return "0x" + hex.EncodeToString(input[:4])
}

func normalizedCallType(value string) string {
	value = strings.ToUpper(strings.TrimSpace(value))
	if value == "" {
		return "CALL"
	}
	return value
}

func topicAddress(topic common.Hash) common.Address {
	var address common.Address
	copy(address[:], topic[12:])
	return address
}
