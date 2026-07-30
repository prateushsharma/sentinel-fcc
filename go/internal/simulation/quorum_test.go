package simulation

import (
	"encoding/json"
	"math/big"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"extension-scaffold/pkg/protocol"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/common/hexutil"
)

const (
	testLatestNumber = "0x3e8"
	testAnchorNumber = "0x3e7"
)

var testAnchorHash = common.HexToHash("0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")

type mockRPC struct {
	transferAmount string
}

func (mock mockRPC) handler(writer http.ResponseWriter, request *http.Request) {
	var payload rpcRequest
	if err := json.NewDecoder(request.Body).Decode(&payload); err != nil {
		http.Error(writer, err.Error(), http.StatusBadRequest)
		return
	}

	var result any
	switch payload.Method {
	case "eth_getBlockByNumber":
		var params []json.RawMessage
		_ = remarshal(payload.Params, &params)
		var block string
		_ = json.Unmarshal(params[0], &block)
		number := testAnchorNumber
		if block == "latest" {
			number = testLatestNumber
		}
		result = blockHeader{
			Number: number,
			Hash:   testAnchorHash,
		}

	case "eth_getCode":
		result = "0x6001600055"

	case "debug_traceCall":
		amount, _ := new(big.Int).SetString(mock.transferAmount, 10)
		data := make([]byte, 32)
		amount.FillBytes(data)
		result = callFrame{
			Type:   "CALL",
			From:   common.HexToAddress("0x2222222222222222222222222222222222222222"),
			To:     common.HexToAddress("0x5555555555555555555555555555555555555555"),
			Value:  "0x0",
			Input:  hexutil.Bytes{0xa9, 0x05, 0x9c, 0xbb},
			Output: hexutil.Bytes{},
			Logs: []traceLog{
				{
					Address: common.HexToAddress("0x5555555555555555555555555555555555555555"),
					Topics: []common.Hash{
						transferTopic,
						addressTopic(common.HexToAddress("0x2222222222222222222222222222222222222222")),
						addressTopic(common.HexToAddress("0x7777777777777777777777777777777777777777")),
					},
					Data: hexutil.Bytes(data),
				},
			},
		}

	default:
		http.Error(writer, "unsupported method", http.StatusBadRequest)
		return
	}

	response := rpcResponse{
		JSONRPC: "2.0",
		ID:      payload.ID,
	}
	encoded, _ := json.Marshal(result)
	response.Result = encoded
	writer.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(writer).Encode(response)
}

func TestQuorumSimulatorAgreesOnCanonicalEffects(t *testing.T) {
	first := httptest.NewServer(http.HandlerFunc(mockRPC{transferAmount: "50"}.handler))
	defer first.Close()
	second := httptest.NewServer(http.HandlerFunc(mockRPC{transferAmount: "50"}.handler))
	defer second.Close()

	simulator, err := NewQuorumSimulator(
		[]ProviderConfig{{URL: first.URL}, {URL: second.URL}},
		2,
		2*time.Second,
	)
	if err != nil {
		t.Fatal(err)
	}

	result, err := simulator.Simulate(t.Context(), testIntent())
	if err != nil {
		t.Fatal(err)
	}

	if !result.Snapshot.ProviderAgreement {
		t.Fatal("matching providers did not reach agreement")
	}
	if !result.Snapshot.Success {
		t.Fatal("successful trace was marked failed")
	}
	if result.Snapshot.BlockNumber != 999 ||
		result.Snapshot.ObservedBlockNumber != 1000 ||
		result.Snapshot.BlockHash != testAnchorHash {
		t.Fatalf("unexpected block anchor: %+v", result.Snapshot)
	}
	if len(result.Effects.TokenTransfers) != 1 ||
		result.Effects.TokenTransfers[0].Amount != "50" {
		t.Fatalf("unexpected normalized transfer: %+v", result.Effects.TokenTransfers)
	}
}

func TestQuorumSimulatorProducesDeterministicDisagreement(t *testing.T) {
	first := httptest.NewServer(http.HandlerFunc(mockRPC{transferAmount: "50"}.handler))
	defer first.Close()
	second := httptest.NewServer(http.HandlerFunc(mockRPC{transferAmount: "75"}.handler))
	defer second.Close()

	simulator, err := NewQuorumSimulator(
		[]ProviderConfig{{URL: first.URL}, {URL: second.URL}},
		2,
		2*time.Second,
	)
	if err != nil {
		t.Fatal(err)
	}

	firstResult, err := simulator.Simulate(t.Context(), testIntent())
	if err != nil {
		t.Fatal(err)
	}
	secondResult, err := simulator.Simulate(t.Context(), testIntent())
	if err != nil {
		t.Fatal(err)
	}

	if firstResult.Snapshot.ProviderAgreement {
		t.Fatal("conflicting providers reached agreement")
	}
	if firstResult.Snapshot.EffectsHash == (common.Hash{}) {
		t.Fatal("disagreement evidence hash is zero")
	}
	if firstResult.Snapshot.EffectsHash != secondResult.Snapshot.EffectsHash {
		t.Fatal("identical disagreement produced different evidence hashes")
	}
}

func remarshal(input any, output any) error {
	encoded, err := json.Marshal(input)
	if err != nil {
		return err
	}
	return json.Unmarshal(encoded, output)
}

func addressTopic(address common.Address) common.Hash {
	var topic common.Hash
	copy(topic[12:], address[:])
	return topic
}

func testIntent() protocol.TransactionIntent {
	return protocol.TransactionIntent{
		ProtocolVersion: protocol.CurrentProtocolVersion,
		ChainID:         big.NewInt(114),
		Executor:        common.HexToAddress("0x2222222222222222222222222222222222222222"),
		Account:         common.HexToAddress("0x2222222222222222222222222222222222222222"),
		Agent:           common.HexToAddress("0x3333333333333333333333333333333333333333"),
		Target:          common.HexToAddress("0x5555555555555555555555555555555555555555"),
		Value:           big.NewInt(0),
		Data:            []byte{0xa9, 0x05, 0x9c, 0xbb},
		Nonce:           0,
		ValidAfter:      100,
		ValidUntil:      5_000,
	}
}
