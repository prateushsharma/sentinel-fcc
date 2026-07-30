package simulation

import (
	"math/big"
	"testing"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/common/hexutil"
)

func TestNormalizeTraceCommitsCallsTransfersApprovalsAndLogs(t *testing.T) {
	amount := make([]byte, 32)
	big.NewInt(42).FillBytes(amount)

	frame := callFrame{
		Type:   "CALL",
		From:   common.HexToAddress("0x1111111111111111111111111111111111111111"),
		To:     common.HexToAddress("0x2222222222222222222222222222222222222222"),
		Value:  "0x5",
		Input:  hexutil.Bytes{0x09, 0x5e, 0xa7, 0xb3},
		Output: hexutil.Bytes{0x01},
		Logs: []traceLog{
			{
				Address: common.HexToAddress("0x2222222222222222222222222222222222222222"),
				Topics: []common.Hash{
					approvalTopic,
					addressTopic(common.HexToAddress("0x1111111111111111111111111111111111111111")),
					addressTopic(common.HexToAddress("0x3333333333333333333333333333333333333333")),
				},
				Data: hexutil.Bytes(amount),
			},
		},
	}

	effects, hash, err := normalizeTrace(frame)
	if err != nil {
		t.Fatal(err)
	}
	if hash == (common.Hash{}) {
		t.Fatal("effects hash is zero")
	}
	if len(effects.Calls) != 1 || effects.Calls[0].Selector != "0x095ea7b3" {
		t.Fatalf("unexpected call effects: %+v", effects.Calls)
	}
	if len(effects.NativeTransfers) != 1 || effects.NativeTransfers[0].Value != "5" {
		t.Fatalf("unexpected native transfers: %+v", effects.NativeTransfers)
	}
	if len(effects.TokenApprovals) != 1 || effects.TokenApprovals[0].Amount != "42" {
		t.Fatalf("unexpected token approvals: %+v", effects.TokenApprovals)
	}
	if len(effects.Logs) != 1 {
		t.Fatalf("unexpected log count: %d", len(effects.Logs))
	}
}
