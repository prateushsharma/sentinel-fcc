package simulation

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"sync/atomic"
	"time"

	"extension-scaffold/pkg/protocol"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/common/hexutil"
)

const maxRPCResponseBytes = 8 * 1024 * 1024

type rpcProvider struct {
	index    int
	endpoint string
	client   *http.Client
	nextID   atomic.Uint64
}

type rpcRequest struct {
	JSONRPC string `json:"jsonrpc"`
	ID      uint64 `json:"id"`
	Method  string `json:"method"`
	Params  any    `json:"params"`
}

type rpcResponse struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      uint64          `json:"id"`
	Result  json.RawMessage `json:"result"`
	Error   *rpcError       `json:"error,omitempty"`
}

type rpcError struct {
	Code    int             `json:"code"`
	Message string          `json:"message"`
	Data    json.RawMessage `json:"data,omitempty"`
}

type blockHeader struct {
	Number string      `json:"number"`
	Hash   common.Hash `json:"hash"`
}

type traceLog struct {
	Address common.Address `json:"address"`
	Topics  []common.Hash  `json:"topics"`
	Data    hexutil.Bytes  `json:"data"`
}

type callFrame struct {
	Type         string         `json:"type"`
	From         common.Address `json:"from"`
	To           common.Address `json:"to"`
	Value        string         `json:"value"`
	Input        hexutil.Bytes  `json:"input"`
	Output       hexutil.Bytes  `json:"output"`
	Error        string         `json:"error"`
	RevertReason string         `json:"revertReason"`
	Calls        []callFrame    `json:"calls"`
	Logs         []traceLog     `json:"logs"`
}

func newRPCProvider(index int, endpoint string, timeout time.Duration) (*rpcProvider, error) {
	if endpoint == "" {
		return nil, fmt.Errorf("empty endpoint")
	}
	return &rpcProvider{
		index:    index,
		endpoint: endpoint,
		client: &http.Client{
			Timeout: timeout,
			CheckRedirect: func(_ *http.Request, _ []*http.Request) error {
				return http.ErrUseLastResponse
			},
		},
	}, nil
}

func (provider *rpcProvider) call(
	ctx context.Context,
	method string,
	params any,
	result any,
) error {
	id := provider.nextID.Add(1)
	payload, err := json.Marshal(rpcRequest{
		JSONRPC: "2.0",
		ID:      id,
		Method:  method,
		Params:  params,
	})
	if err != nil {
		return fmt.Errorf("encode %s request: %w", method, err)
	}

	request, err := http.NewRequestWithContext(
		ctx,
		http.MethodPost,
		provider.endpoint,
		bytes.NewReader(payload),
	)
	if err != nil {
		return fmt.Errorf("create %s request: %w", method, err)
	}
	request.Header.Set("Content-Type", "application/json")

	response, err := provider.client.Do(request)
	if err != nil {
		return fmt.Errorf("provider %d %s request: %w", provider.index, method, err)
	}
	defer response.Body.Close()

	body, err := io.ReadAll(io.LimitReader(response.Body, maxRPCResponseBytes+1))
	if err != nil {
		return fmt.Errorf("read provider %d %s response: %w", provider.index, method, err)
	}
	if len(body) > maxRPCResponseBytes {
		return fmt.Errorf("provider %d %s response exceeds limit", provider.index, method)
	}
	if response.StatusCode != http.StatusOK {
		return fmt.Errorf(
			"provider %d %s returned HTTP %d",
			provider.index,
			method,
			response.StatusCode,
		)
	}

	var decoded rpcResponse
	if err := json.Unmarshal(body, &decoded); err != nil {
		return fmt.Errorf("decode provider %d %s response: %w", provider.index, method, err)
	}
	if decoded.JSONRPC != "2.0" {
		return fmt.Errorf("provider %d %s returned invalid JSON-RPC version", provider.index, method)
	}
	if decoded.ID != id {
		return fmt.Errorf("provider %d %s response ID mismatch", provider.index, method)
	}
	if decoded.Error != nil {
		return fmt.Errorf(
			"provider %d %s RPC error %d: %s",
			provider.index,
			method,
			decoded.Error.Code,
			decoded.Error.Message,
		)
	}
	if len(decoded.Result) == 0 || bytes.Equal(decoded.Result, []byte("null")) {
		return fmt.Errorf("provider %d %s returned null result", provider.index, method)
	}
	if err := json.Unmarshal(decoded.Result, result); err != nil {
		return fmt.Errorf("decode provider %d %s result: %w", provider.index, method, err)
	}
	return nil
}

func (provider *rpcProvider) header(
	ctx context.Context,
	block string,
) (blockHeader, error) {
	var header blockHeader
	if err := provider.call(
		ctx,
		"eth_getBlockByNumber",
		[]any{block, false},
		&header,
	); err != nil {
		return blockHeader{}, err
	}
	if header.Hash == (common.Hash{}) {
		return blockHeader{}, fmt.Errorf("provider %d returned zero block hash", provider.index)
	}
	if _, err := parseHexUint64(header.Number); err != nil {
		return blockHeader{}, fmt.Errorf("provider %d invalid block number: %w", provider.index, err)
	}
	return header, nil
}

func (provider *rpcProvider) code(
	ctx context.Context,
	target common.Address,
	block string,
) ([]byte, error) {
	var encoded string
	if err := provider.call(
		ctx,
		"eth_getCode",
		[]any{target.Hex(), block},
		&encoded,
	); err != nil {
		return nil, err
	}
	code, err := hexutil.Decode(encoded)
	if err != nil {
		return nil, fmt.Errorf("provider %d decode target code: %w", provider.index, err)
	}
	return code, nil
}

func (provider *rpcProvider) trace(
	ctx context.Context,
	intent protocol.TransactionIntent,
	block string,
) (callFrame, error) {
	callObject := map[string]string{
		"from":  intent.Executor.Hex(),
		"to":    intent.Target.Hex(),
		"value": hexutil.EncodeBig(intent.Value),
		"data":  hexutil.Encode(intent.Data),
	}

	traceConfig := map[string]any{
		"tracer":  "callTracer",
		"timeout": "8s",
		"tracerConfig": map[string]any{
			"onlyTopCall": false,
			"withLog":     true,
		},
	}

	var frame callFrame
	if err := provider.call(
		ctx,
		"debug_traceCall",
		[]any{callObject, block, traceConfig},
		&frame,
	); err != nil {
		return callFrame{}, err
	}
	return frame, nil
}

func parseHexUint64(value string) (uint64, error) {
	if len(value) < 3 || value[:2] != "0x" {
		return 0, fmt.Errorf("invalid hex uint64 %q", value)
	}
	parsed, ok := new(big.Int).SetString(value[2:], 16)
	if !ok || parsed.Sign() < 0 || parsed.BitLen() > 64 {
		return 0, fmt.Errorf("invalid hex uint64 %q", value)
	}
	return parsed.Uint64(), nil
}
