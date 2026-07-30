#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

readonly EXPECTED_ORIGIN_SLUG="prateushsharma/sentinel-fcc"
readonly PRIMARY_BASE_BRANCH="feat/confidential-policy-engine"
readonly FALLBACK_BASE_BRANCH="develop"
readonly FEATURE_BRANCH="feat/quorum-simulation"
readonly ARCHIVE_RELATIVE_PATH="scripts/patches/007-quorum-simulation.sh"

SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/$(basename -- "${BASH_SOURCE[0]}")"
SCRIPT_BASENAME="$(basename -- "$SCRIPT_PATH")"
PROJECT_ROOT="${1:-$(pwd)}"
PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd)"
BASE_BRANCH=""

info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

trap 'die "Patch failed at line $LINENO while running: $BASH_COMMAND"' ERR

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

normalize_github_slug() {
  local url="$1"
  url="${url%.git}"
  url="${url#git@github.com:}"
  url="${url#ssh://git@github.com/}"
  url="${url#https://github.com/}"
  url="${url#http://github.com/}"
  printf '%s' "$url"
}

validate_and_create_branch() {
  local current_branch origin_url origin_slug status_line current_sha remote_sha

  [[ -d "$PROJECT_ROOT/.git" ]] || die "Not a Git repository: $PROJECT_ROOT"

  current_branch="$(git -C "$PROJECT_ROOT" branch --show-current)"
  case "$current_branch" in
    "$PRIMARY_BASE_BRANCH"|"$FALLBACK_BASE_BRANCH")
      BASE_BRANCH="$current_branch"
      ;;
    *)
      die "Run Patch 007 from '$PRIMARY_BASE_BRANCH' or '$FALLBACK_BASE_BRANCH'; current branch is '$current_branch'."
      ;;
  esac

  origin_url="$(git -C "$PROJECT_ROOT" remote get-url origin 2>/dev/null || true)"
  origin_slug="$(normalize_github_slug "$origin_url")"
  [[ "$origin_slug" == "$EXPECTED_ORIGIN_SLUG" ]] ||
    die "Unexpected origin remote: $origin_url"

  git -C "$PROJECT_ROOT" fetch origin "$BASE_BRANCH" --prune
  current_sha="$(git -C "$PROJECT_ROOT" rev-parse HEAD)"
  remote_sha="$(git -C "$PROJECT_ROOT" rev-parse "origin/$BASE_BRANCH")"
  [[ "$current_sha" == "$remote_sha" ]] ||
    die "Local $BASE_BRANCH is not synchronized with origin/$BASE_BRANCH."

  while IFS= read -r status_line; do
    [[ -z "$status_line" ]] && continue
    if [[ "$(dirname -- "$SCRIPT_PATH")" == "$PROJECT_ROOT" && "$status_line" == "?? $SCRIPT_BASENAME" ]]; then
      continue
    fi
    printf '%s\n' "$status_line" >&2
    die "Working tree contains unrelated changes."
  done < <(git -C "$PROJECT_ROOT" status --porcelain=v1 --untracked-files=all)

  for required in \
    go/internal/policyengine/types.go \
    go/internal/extension/sentinel.go \
    go/internal/extension/sentinel_test.go \
    go/internal/extension/extension.go \
    go/pkg/types/sentinel.go \
    go/pkg/protocol/hashing.go \
    contracts/SentinelExecutor.sol; do
    [[ -f "$PROJECT_ROOT/$required" ]] ||
      die "Required prior-stage file is missing: $required"
  done

  if git -C "$PROJECT_ROOT" show-ref --verify --quiet "refs/heads/$FEATURE_BRANCH"; then
    die "Local branch already exists: $FEATURE_BRANCH"
  fi
  if git -C "$PROJECT_ROOT" ls-remote --exit-code --heads origin "$FEATURE_BRANCH" >/dev/null 2>&1; then
    die "Remote branch already exists: $FEATURE_BRANCH"
  fi

  git -C "$PROJECT_ROOT" switch -c "$FEATURE_BRANCH"
  ok "Created feature branch: $FEATURE_BRANCH"
  info "Pull-request base will be: $BASE_BRANCH"
}

write_simulation_package() {
  mkdir -p "$PROJECT_ROOT/go/internal/simulation"

  cat > "$PROJECT_ROOT/go/internal/simulation/types.go" <<'EOF'
// Package simulation obtains deterministic, quorum-checked EVM call effects.
package simulation

import (
	"time"

	"extension-scaffold/internal/policyengine"
	"extension-scaffold/pkg/protocol"

	"github.com/ethereum/go-ethereum/common"
)

// ProviderConfig identifies one independent JSON-RPC endpoint.
type ProviderConfig struct {
	URL string
}

// NativeTransfer is a value-bearing call observed in trace order.
type NativeTransfer struct {
	Depth uint16         `json:"depth"`
	From  common.Address `json:"from"`
	To    common.Address `json:"to"`
	Value string         `json:"value"`
}

// CallEffect commits to one traced call frame while omitting client-specific gas text.
type CallEffect struct {
	Depth      uint16         `json:"depth"`
	Type       string         `json:"type"`
	From       common.Address `json:"from"`
	To         common.Address `json:"to"`
	Value      string         `json:"value"`
	Selector   string         `json:"selector"`
	InputHash  common.Hash    `json:"inputHash"`
	OutputHash common.Hash    `json:"outputHash"`
	Success    bool           `json:"success"`
}

// TokenTransfer is extracted from a canonical Transfer event.
type TokenTransfer struct {
	Token  common.Address `json:"token"`
	From   common.Address `json:"from"`
	To     common.Address `json:"to"`
	Amount string         `json:"amount"`
}

// TokenApproval is extracted from a canonical Approval event.
type TokenApproval struct {
	Token   common.Address `json:"token"`
	Owner   common.Address `json:"owner"`
	Spender common.Address `json:"spender"`
	Amount  string         `json:"amount"`
}

// LogEffect commits to every trace log, including events Sentinel does not decode.
type LogEffect struct {
	Emitter  common.Address `json:"emitter"`
	Topics   []common.Hash  `json:"topics"`
	DataHash common.Hash    `json:"dataHash"`
}

// NormalizedEffects is the deterministic simulation commitment preimage.
type NormalizedEffects struct {
	Version         uint16           `json:"version"`
	Success         bool             `json:"success"`
	ReturnDataHash  common.Hash      `json:"returnDataHash"`
	Calls           []CallEffect     `json:"calls"`
	NativeTransfers []NativeTransfer `json:"nativeTransfers"`
	TokenTransfers  []TokenTransfer  `json:"tokenTransfers"`
	TokenApprovals  []TokenApproval  `json:"tokenApprovals"`
	Logs            []LogEffect      `json:"logs"`
}

// Result contains the engine snapshot plus the agreed normalized effects.
type Result struct {
	Snapshot policyengine.SimulationSnapshot
	Effects  NormalizedEffects
}

// Simulator derives one snapshot for the exact intent.
type Simulator interface {
	Simulate(context.Context, protocol.TransactionIntent) (Result, error)
}

// QuorumSimulator queries independent providers at one canonical historical block.
type QuorumSimulator struct {
	providers []*rpcProvider
	quorum    int
	timeout   time.Duration
}
EOF

  # Fix the missing context import in the generated types file.
  python3 - "$PROJECT_ROOT/go/internal/simulation/types.go" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
text = text.replace(
    'import (\n\t"time"\n',
    'import (\n\t"context"\n\t"time"\n',
    1,
)
path.write_text(text, encoding="utf-8")
PY

  cat > "$PROJECT_ROOT/go/internal/simulation/config.go" <<'EOF'
package simulation

import (
	"fmt"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
)

const (
	envRPCURLs = "SENTINEL_RPC_URLS"
	envQuorum  = "SENTINEL_RPC_QUORUM"
	envTimeout = "SENTINEL_RPC_TIMEOUT"

	defaultTimeout = 12 * time.Second
)

// NewFromEnvironment constructs a simulator from comma-separated RPC URLs.
//
// Example:
// SENTINEL_RPC_URLS=https://rpc-a.example,https://rpc-b.example
// SENTINEL_RPC_QUORUM=2
// SENTINEL_RPC_TIMEOUT=12s
func NewFromEnvironment() (*QuorumSimulator, error) {
	rawURLs := strings.TrimSpace(os.Getenv(envRPCURLs))
	if rawURLs == "" {
		return nil, fmt.Errorf("%s is not configured", envRPCURLs)
	}

	parts := strings.Split(rawURLs, ",")
	configs := make([]ProviderConfig, 0, len(parts))
	seen := make(map[string]struct{}, len(parts))
	for index, part := range parts {
		endpoint := strings.TrimSpace(part)
		if endpoint == "" {
			return nil, fmt.Errorf("%s contains an empty URL at position %d", envRPCURLs, index)
		}

		parsed, err := url.Parse(endpoint)
		if err != nil {
			return nil, fmt.Errorf("parse RPC URL %d: %w", index, err)
		}
		if parsed.Scheme != "http" && parsed.Scheme != "https" {
			return nil, fmt.Errorf("RPC URL %d must use http or https", index)
		}
		if parsed.Host == "" || parsed.Fragment != "" {
			return nil, fmt.Errorf("RPC URL %d is malformed", index)
		}
		if _, exists := seen[endpoint]; exists {
			return nil, fmt.Errorf("duplicate RPC URL at position %d", index)
		}
		seen[endpoint] = struct{}{}
		configs = append(configs, ProviderConfig{URL: endpoint})
	}

	quorum := len(configs)/2 + 1
	if rawQuorum := strings.TrimSpace(os.Getenv(envQuorum)); rawQuorum != "" {
		parsed, err := strconv.Atoi(rawQuorum)
		if err != nil {
			return nil, fmt.Errorf("parse %s: %w", envQuorum, err)
		}
		quorum = parsed
	}

	timeout := defaultTimeout
	if rawTimeout := strings.TrimSpace(os.Getenv(envTimeout)); rawTimeout != "" {
		parsed, err := time.ParseDuration(rawTimeout)
		if err != nil {
			return nil, fmt.Errorf("parse %s: %w", envTimeout, err)
		}
		timeout = parsed
	}

	return NewQuorumSimulator(configs, quorum, timeout)
}

// NewQuorumSimulator validates configuration and creates a simulator.
func NewQuorumSimulator(
	configs []ProviderConfig,
	quorum int,
	timeout time.Duration,
) (*QuorumSimulator, error) {
	if len(configs) == 0 {
		return nil, fmt.Errorf("at least one RPC provider is required")
	}
	if quorum <= 0 || quorum > len(configs) {
		return nil, fmt.Errorf("quorum %d is invalid for %d providers", quorum, len(configs))
	}
	if timeout <= 0 {
		return nil, fmt.Errorf("RPC timeout must be positive")
	}

	providers := make([]*rpcProvider, len(configs))
	for index, config := range configs {
		provider, err := newRPCProvider(index, config.URL, timeout)
		if err != nil {
			return nil, fmt.Errorf("configure provider %d: %w", index, err)
		}
		providers[index] = provider
	}

	return &QuorumSimulator{
		providers: providers,
		quorum:    quorum,
		timeout:   timeout,
	}, nil
}
EOF

  cat > "$PROJECT_ROOT/go/internal/simulation/rpc.go" <<'EOF'
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
EOF

  cat > "$PROJECT_ROOT/go/internal/simulation/normalize.go" <<'EOF'
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
	maxTraceDepth   = 128
	maxTraceFrames  = 4096
	maxTraceLogs    = 8192
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
EOF

  cat > "$PROJECT_ROOT/go/internal/simulation/quorum.go" <<'EOF'
package simulation

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"
	"sync"

	"extension-scaffold/internal/policyengine"
	"extension-scaffold/pkg/protocol"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
)

type headerObservation struct {
	provider *rpcProvider
	header   blockHeader
	number   uint64
	err      error
}

type providerSimulation struct {
	provider       *rpcProvider
	blockHash      common.Hash
	effects        NormalizedEffects
	effectsHash    common.Hash
	success        bool
	targetCodeHash common.Hash
	consensusHash  common.Hash
	err            error
}

type consensusPreimage struct {
	EffectsHash    common.Hash `json:"effectsHash"`
	Success        bool        `json:"success"`
	TargetCodeHash common.Hash `json:"targetCodeHash"`
}

type disagreementPreimage struct {
	Version     uint16        `json:"version"`
	BlockNumber uint64        `json:"blockNumber"`
	BlockHash   common.Hash   `json:"blockHash"`
	Digests     []common.Hash `json:"digests"`
}

// Simulate anchors providers to one historical block and requires matching effects.
func (simulator *QuorumSimulator) Simulate(
	parent context.Context,
	intent protocol.TransactionIntent,
) (Result, error) {
	if err := protocol.ValidateTransactionIntent(intent); err != nil {
		return Result{}, fmt.Errorf("validate simulation intent: %w", err)
	}

	ctx, cancel := context.WithTimeout(parent, simulator.timeout)
	defer cancel()

	latest := simulator.observeHeaders(ctx, "latest", simulator.providers)
	successfulLatest := make([]headerObservation, 0, len(latest))
	for _, observation := range latest {
		if observation.err == nil {
			successfulLatest = append(successfulLatest, observation)
		}
	}
	if len(successfulLatest) < simulator.quorum {
		return Result{}, fmt.Errorf(
			"only %d of %d providers returned a latest block; quorum is %d",
			len(successfulLatest),
			len(simulator.providers),
			simulator.quorum,
		)
	}

	minimumLatest := successfulLatest[0].number
	for _, observation := range successfulLatest[1:] {
		if observation.number < minimumLatest {
			minimumLatest = observation.number
		}
	}
	if minimumLatest == 0 {
		return Result{}, fmt.Errorf("cannot select a historical block before genesis")
	}

	anchorNumber := minimumLatest - 1
	anchorTag := encodeBlockNumber(anchorNumber)

	candidates := make([]*rpcProvider, len(successfulLatest))
	for index, observation := range successfulLatest {
		candidates[index] = observation.provider
	}

	anchors := simulator.observeHeaders(ctx, anchorTag, candidates)
	hashGroups := make(map[common.Hash][]*rpcProvider)
	for _, observation := range anchors {
		if observation.err == nil && observation.number == anchorNumber {
			hashGroups[observation.header.Hash] = append(
				hashGroups[observation.header.Hash],
				observation.provider,
			)
		}
	}

	anchorHash, anchoredProviders, ok := largestHeaderGroup(hashGroups)
	if !ok || len(anchoredProviders) < simulator.quorum {
		return Result{}, fmt.Errorf(
			"providers could not establish canonical block %d with quorum %d",
			anchorNumber,
			simulator.quorum,
		)
	}

	simulations := simulator.simulateProviders(
		ctx,
		anchoredProviders,
		intent,
		anchorTag,
		anchorHash,
	)

	successful := make([]providerSimulation, 0, len(simulations))
	consensusGroups := make(map[common.Hash][]providerSimulation)
	for _, result := range simulations {
		if result.err != nil {
			continue
		}
		successful = append(successful, result)
		consensusGroups[result.consensusHash] = append(
			consensusGroups[result.consensusHash],
			result,
		)
	}
	if len(successful) < simulator.quorum {
		return Result{}, fmt.Errorf(
			"only %d providers completed simulation; quorum is %d",
			len(successful),
			simulator.quorum,
		)
	}

	_, agreed, agreement := largestSimulationGroup(consensusGroups)
	if agreement && len(agreed) >= simulator.quorum {
		chosen := agreed[0]
		return Result{
			Snapshot: policyengine.SimulationSnapshot{
				IntentHash:          mustIntentHash(intent),
				BlockNumber:         anchorNumber,
				BlockHash:           anchorHash,
				ObservedBlockNumber: minimumLatest,
				EffectsHash:         chosen.effectsHash,
				Success:             chosen.success,
				ProviderAgreement:   true,
				TargetCodeHash:      chosen.targetCodeHash,
			},
			Effects: chosen.effects,
		}, nil
	}

	disagreementHash, err := hashDisagreement(anchorNumber, anchorHash, successful)
	if err != nil {
		return Result{}, err
	}
	return Result{
		Snapshot: policyengine.SimulationSnapshot{
			IntentHash:          mustIntentHash(intent),
			BlockNumber:         anchorNumber,
			BlockHash:           anchorHash,
			ObservedBlockNumber: minimumLatest,
			EffectsHash:         disagreementHash,
			Success:             false,
			ProviderAgreement:   false,
			TargetCodeHash:      common.Hash{},
		},
		Effects: NormalizedEffects{
			Version: effectsVersion,
			Success: false,
		},
	}, nil
}

func (simulator *QuorumSimulator) observeHeaders(
	ctx context.Context,
	block string,
	providers []*rpcProvider,
) []headerObservation {
	results := make(chan headerObservation, len(providers))
	var waitGroup sync.WaitGroup
	waitGroup.Add(len(providers))

	for _, provider := range providers {
		provider := provider
		go func() {
			defer waitGroup.Done()
			header, err := provider.header(ctx, block)
			observation := headerObservation{
				provider: provider,
				header:   header,
				err:      err,
			}
			if err == nil {
				observation.number, observation.err = parseHexUint64(header.Number)
			}
			results <- observation
		}()
	}

	waitGroup.Wait()
	close(results)

	observations := make([]headerObservation, 0, len(providers))
	for result := range results {
		observations = append(observations, result)
	}
	sort.Slice(observations, func(i, j int) bool {
		return observations[i].provider.index < observations[j].provider.index
	})
	return observations
}

func (simulator *QuorumSimulator) simulateProviders(
	ctx context.Context,
	providers []*rpcProvider,
	intent protocol.TransactionIntent,
	blockTag string,
	anchorHash common.Hash,
) []providerSimulation {
	results := make(chan providerSimulation, len(providers))
	var waitGroup sync.WaitGroup
	waitGroup.Add(len(providers))

	for _, provider := range providers {
		provider := provider
		go func() {
			defer waitGroup.Done()
			results <- simulateProvider(ctx, provider, intent, blockTag, anchorHash)
		}()
	}

	waitGroup.Wait()
	close(results)

	simulations := make([]providerSimulation, 0, len(providers))
	for result := range results {
		simulations = append(simulations, result)
	}
	sort.Slice(simulations, func(i, j int) bool {
		return simulations[i].provider.index < simulations[j].provider.index
	})
	return simulations
}

func simulateProvider(
	ctx context.Context,
	provider *rpcProvider,
	intent protocol.TransactionIntent,
	blockTag string,
	anchorHash common.Hash,
) providerSimulation {
	result := providerSimulation{provider: provider}

	trace, err := provider.trace(ctx, intent, blockTag)
	if err != nil {
		result.err = err
		return result
	}
	code, err := provider.code(ctx, intent.Target, blockTag)
	if err != nil {
		result.err = err
		return result
	}

	headerAfter, err := provider.header(ctx, blockTag)
	if err != nil {
		result.err = err
		return result
	}
	if headerAfter.Hash != anchorHash {
		result.err = fmt.Errorf("provider %d reorged during simulation", provider.index)
		return result
	}

	effects, effectsHash, err := normalizeTrace(trace)
	if err != nil {
		result.err = fmt.Errorf("normalize provider %d trace: %w", provider.index, err)
		return result
	}

	result.blockHash = anchorHash
	result.effects = effects
	result.effectsHash = effectsHash
	result.success = effects.Success
	result.targetCodeHash = crypto.Keccak256Hash(code)

	encoded, err := json.Marshal(consensusPreimage{
		EffectsHash:    result.effectsHash,
		Success:        result.success,
		TargetCodeHash: result.targetCodeHash,
	})
	if err != nil {
		result.err = fmt.Errorf("marshal provider consensus preimage: %w", err)
		return result
	}
	result.consensusHash = crypto.Keccak256Hash(encoded)
	return result
}

func largestHeaderGroup(
	groups map[common.Hash][]*rpcProvider,
) (common.Hash, []*rpcProvider, bool) {
	var selectedHash common.Hash
	var selected []*rpcProvider

	hashes := make([]common.Hash, 0, len(groups))
	for hash := range groups {
		hashes = append(hashes, hash)
	}
	sort.Slice(hashes, func(i, j int) bool {
		return string(hashes[i][:]) < string(hashes[j][:])
	})

	for _, hash := range hashes {
		group := groups[hash]
		if len(group) > len(selected) {
			selectedHash = hash
			selected = group
		}
	}
	return selectedHash, selected, len(selected) > 0
}

func largestSimulationGroup(
	groups map[common.Hash][]providerSimulation,
) (common.Hash, []providerSimulation, bool) {
	var selectedHash common.Hash
	var selected []providerSimulation

	hashes := make([]common.Hash, 0, len(groups))
	for hash := range groups {
		hashes = append(hashes, hash)
	}
	sort.Slice(hashes, func(i, j int) bool {
		return string(hashes[i][:]) < string(hashes[j][:])
	})

	for _, hash := range hashes {
		group := groups[hash]
		if len(group) > len(selected) {
			selectedHash = hash
			selected = group
		}
	}
	return selectedHash, selected, len(selected) > 0
}

func hashDisagreement(
	blockNumber uint64,
	blockHash common.Hash,
	results []providerSimulation,
) (common.Hash, error) {
	digests := make([]common.Hash, len(results))
	for index, result := range results {
		digests[index] = result.consensusHash
	}
	sort.Slice(digests, func(i, j int) bool {
		return string(digests[i][:]) < string(digests[j][:])
	})

	encoded, err := json.Marshal(disagreementPreimage{
		Version:     1,
		BlockNumber: blockNumber,
		BlockHash:   blockHash,
		Digests:     digests,
	})
	if err != nil {
		return common.Hash{}, fmt.Errorf("marshal disagreement evidence: %w", err)
	}
	return crypto.Keccak256Hash(encoded), nil
}

func mustIntentHash(intent protocol.TransactionIntent) common.Hash {
	hash, err := protocol.HashTransactionIntent(intent)
	if err != nil {
		panic(err)
	}
	return hash
}

func encodeBlockNumber(number uint64) string {
	return fmt.Sprintf("0x%x", number)
}
EOF
}

modify_extension_for_simulation() {
  cat > "$PROJECT_ROOT/go/internal/extension/simulator.go" <<'EOF'
package extension

import (
	"context"

	"extension-scaffold/internal/simulation"
	"extension-scaffold/pkg/protocol"
)

type intentSimulator interface {
	Simulate(context.Context, protocol.TransactionIntent) (simulation.Result, error)
}
EOF

  cat > "$PROJECT_ROOT/go/internal/extension/sentinel.go" <<'EOF'
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
EOF

  python3 - "$PROJECT_ROOT/go/internal/extension/extension.go" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

import_anchor = '"extension-scaffold/internal/config"\n'
import_addition = '"extension-scaffold/internal/simulation"\n'
if import_addition not in text:
    if import_anchor not in text:
        raise SystemExit("extension.go config import anchor was not found")
    text = text.replace(import_anchor, import_anchor + "\t" + import_addition, 1)

struct_anchor = "\tdecryptor requestDecryptor\n"
struct_addition = "\tsimulator    intentSimulator\n\tsimulatorErr error\n"
if "\tsimulator    intentSimulator\n" not in text:
    if struct_anchor not in text:
        raise SystemExit("extension.go decryptor field anchor was not found")
    text = text.replace(struct_anchor, struct_anchor + struct_addition, 1)

old_constructor = "\te := &Extension{decryptor: newNodeDecryptor(signPort)}\n"
new_constructor = """\tsimulator, simulatorErr := simulation.NewFromEnvironment()
\te := &Extension{
\t\tdecryptor:    newNodeDecryptor(signPort),
\t\tsimulator:    simulator,
\t\tsimulatorErr: simulatorErr,
\t}
"""
if old_constructor in text:
    text = text.replace(old_constructor, new_constructor, 1)
elif new_constructor not in text:
    raise SystemExit("extension.go constructor anchor was not found")

path.write_text(text, encoding="utf-8")
PY

  python3 - "$PROJECT_ROOT/go/pkg/types/sentinel.go" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

snapshot_start = text.find("// SentinelSimulationSnapshot is the JSON-safe normalized simulation input.")
if snapshot_start != -1:
    request_marker = "// SentinelEvaluationRequest is decrypted and decoded only inside the extension."
    snapshot_end = text.find(request_marker, snapshot_start)
    if snapshot_end == -1:
        raise SystemExit("could not locate SentinelSimulationSnapshot block end")
    text = text[:snapshot_start] + text[snapshot_end:]

request_start = text.find("type SentinelEvaluationRequest struct {")
if request_start == -1:
    raise SystemExit("SentinelEvaluationRequest block was not found")

brace_start = text.find("{", request_start)
depth = 0
request_end = None
for index in range(brace_start, len(text)):
    character = text[index]
    if character == "{":
        depth += 1
    elif character == "}":
        depth -= 1
        if depth == 0:
            request_end = index + 1
            break

if request_end is None:
    raise SystemExit("could not locate SentinelEvaluationRequest block end")

new_request = """type SentinelEvaluationRequest struct {
\tRequestID      common.Hash              `json:"requestId"`
\tPolicyEnvelope protocol.PolicyEnvelope   `json:"policyEnvelope"`
\tPrivatePolicy  policy.PrivatePolicy      `json:"privatePolicy"`
\tIntent         SentinelTransactionIntent `json:"intent"`
}"""

text = text[:request_start] + new_request + text[request_end:]
path.write_text(text, encoding="utf-8")
PY
}

write_simulation_tests() {
  cat > "$PROJECT_ROOT/go/internal/simulation/quorum_test.go" <<'EOF'
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

var testAnchorHash =
	common.HexToHash("0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")

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
EOF

  cat > "$PROJECT_ROOT/go/internal/simulation/normalize_test.go" <<'EOF'
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
EOF

  cat > "$PROJECT_ROOT/go/internal/extension/sentinel_test.go" <<'EOF'
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
		SchemaVersion:         policy.CurrentSchemaVersion,
		PolicyID:              common.HexToHash("0x1111111111111111111111111111111111111111111111111111111111111111"),
		Owner:                 common.HexToAddress("0x1111111111111111111111111111111111111111"),
		Account:               common.HexToAddress("0x2222222222222222222222222222222222222222"),
		Version:               1,
		ValidAfter:            0,
		ValidUntil:            10_000,
		AllowedChainIDs:       []string{"114"},
		AuthorizedAgents:      []common.Address{
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
EOF
}

write_documentation() {
  cat > "$PROJECT_ROOT/docs/quorum-simulation.md" <<'EOF'
# Quorum Transaction Simulation

## Purpose

Sentinel no longer accepts a simulation snapshot supplied by the agent or
client. The TEE extension derives the snapshot from independent JSON-RPC
providers after decrypting and validating the request.

## Provider configuration

The extension reads:

```text
SENTINEL_RPC_URLS=https://rpc-a.example,https://rpc-b.example,https://rpc-c.example
SENTINEL_RPC_QUORUM=2
SENTINEL_RPC_TIMEOUT=12s
```

`SENTINEL_RPC_QUORUM` defaults to a strict majority. One-provider operation is
supported for local development, but production deployments should use
independently operated providers and quorum greater than one.

## Canonical block anchoring

For each evaluation, Sentinel:

1. requests `latest` from every provider;
2. takes the lowest successfully observed latest block;
3. selects the preceding block so simulation is historical;
4. fetches that exact block from every responsive provider;
5. requires quorum agreement on its hash;
6. rechecks the block hash after each simulation to reject mid-flight reorgs.

If a canonical block cannot be established, evaluation fails without issuing an
executable decision.

## RPC simulation

Every provider receives the same downstream call:

```text
from  = SentinelExecutor
to    = intent target
value = intent value
data  = exact intent calldata
block = quorum-anchored historical block
```

Sentinel calls:

- `debug_traceCall` with the call tracer and logs enabled;
- `eth_getCode` for the target at the same block;
- `eth_getBlockByNumber` again after tracing.

Providers that do not support the required trace method do not contribute to
quorum.

## Normalized effects

Client-specific gas fields and error text are excluded. Sentinel commits to:

- top-level success and return-data hash;
- every call frame in deterministic depth-first trace order;
- call type, addresses, value, selector, input hash, output hash, and success;
- every native-value transfer;
- canonical ERC-20 `Transfer` events;
- canonical ERC-20 `Approval` events;
- every raw log through emitter, topics, and data hash;
- target bytecode hash.

The canonical JSON is hashed with Keccak-256 to create `effectsHash`.

## Agreement and disagreement

A provider result is grouped by:

```text
effectsHash
success
targetCodeHash
```

When at least quorum providers match, `providerAgreement=true` and the agreed
snapshot enters the private policy engine.

When enough providers complete simulation but no group reaches quorum,
Sentinel creates a deterministic hash over the sorted conflicting result
digests and returns:

```text
providerAgreement=false
success=false
effectsHash=<disagreement evidence hash>
```

The policy engine then produces a `PROVIDER_DISAGREEMENT` denial. No provider's
arbitrary effects are selected as authoritative.

## Fail-closed cases

Evaluation fails without an executable decision when:

- too few providers return a latest block;
- providers cannot agree on one historical block hash;
- too few providers complete trace and code queries;
- a provider reorgs during simulation;
- trace size or depth exceeds defensive limits.

The client request schema intentionally contains no simulation field. Unknown
fields are rejected, so an agent cannot inject a trusted-looking snapshot.
EOF

  python3 - "$PROJECT_ROOT/README.md" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
entry = "- [Quorum transaction simulation](docs/quorum-simulation.md)\n"
anchor = "- [Confidential policy engine](docs/confidential-policy-engine.md)\n"

if entry not in text:
    if anchor not in text:
        raise SystemExit("README confidential policy engine anchor was not found")
    text = text.replace(anchor, anchor + entry, 1)

path.write_text(text, encoding="utf-8")
PY
}

archive_patch() {
  mkdir -p "$PROJECT_ROOT/scripts/patches"
  cp "$SCRIPT_PATH" "$PROJECT_ROOT/$ARCHIVE_RELATIVE_PATH"
  chmod 0755 "$PROJECT_ROOT/$ARCHIVE_RELATIVE_PATH"

  if [[ "$(dirname -- "$SCRIPT_PATH")" == "$PROJECT_ROOT" && "$SCRIPT_PATH" != "$PROJECT_ROOT/$ARCHIVE_RELATIVE_PATH" ]]; then
    rm -f "$SCRIPT_PATH"
  fi
}

format_and_verify() {
  cd "$PROJECT_ROOT"
  export PATH="/usr/local/go/bin:$HOME/.foundry/bin:$PATH"
  hash -r

  info "Formatting Go and Solidity sources"
  gofmt -w \
    go/internal/simulation \
    go/internal/extension/simulator.go \
    go/internal/extension/sentinel.go \
    go/internal/extension/sentinel_test.go \
    go/internal/extension/extension.go \
    go/pkg/types/sentinel.go
  forge fmt

  info "Checking scripts and whitespace"
  bash -n "$ARCHIVE_RELATIVE_PATH"
  shellcheck scripts/sentinel/*.sh
  git diff --check

  info "Running focused simulation and extension tests"
  (
    cd go
    go test ./internal/simulation ./internal/extension ./internal/policyengine ./pkg/policy ./pkg/types
  )

  info "Running the complete Sentinel verification suite"
  ./scripts/sentinel/verify.sh

  ok "All simulation, extension, policy, Solidity, Go, scaffold, and conformance checks passed."
}

verify_change_set() {
  cd "$PROJECT_ROOT"

  python3 <<'PY'
import subprocess

allowed_prefixes = (
    "go/internal/simulation/",
)
allowed = {
    "README.md",
    "docs/quorum-simulation.md",
    "go/internal/extension/extension.go",
    "go/internal/extension/sentinel.go",
    "go/internal/extension/sentinel_test.go",
    "go/internal/extension/simulator.go",
    "go/pkg/types/sentinel.go",
    "scripts/patches/007-quorum-simulation.sh",
}

status = subprocess.check_output(
    ["git", "status", "--porcelain=v1", "--untracked-files=all"],
    text=True,
).splitlines()

unexpected = []
for line in status:
    path = line[3:]
    if path in allowed or path.startswith(allowed_prefixes):
        continue
    unexpected.append(line)

if unexpected:
    raise SystemExit(
        "Unexpected files in Patch 007 change set:\n  "
        + "\n  ".join(unexpected)
    )
PY

  ok "Patch 007 changed only intended files."
}

commit_atomic_history() {
  cd "$PROJECT_ROOT"

  git add \
    go/internal/simulation/types.go \
    go/internal/simulation/normalize.go
  git diff --cached --check
  git commit -m "feat(simulation): add canonical effect normalization"

  git add \
    go/internal/simulation/config.go \
    go/internal/simulation/rpc.go \
    go/internal/simulation/quorum.go
  git diff --cached --check
  git commit -m "feat(simulation): add quorum JSON-RPC simulator"

  git add \
    go/internal/extension/simulator.go \
    go/internal/extension/sentinel.go \
    go/internal/extension/extension.go \
    go/pkg/types/sentinel.go
  git diff --cached --check
  git commit -m "feat(extension): derive simulation inside confidential evaluation"

  git add \
    go/internal/simulation/normalize_test.go \
    go/internal/simulation/quorum_test.go \
    go/internal/extension/sentinel_test.go
  git diff --cached --check
  git commit -m "test(simulation): cover quorum and extension integration"

  git add README.md docs/quorum-simulation.md
  git diff --cached --check
  git commit -m "docs(simulation): document quorum effect extraction"

  git add "$ARCHIVE_RELATIVE_PATH"
  git diff --cached --check
  git commit -m "chore(project): archive quorum simulation patch"

  [[ -z "$(git status --porcelain=v1)" ]] ||
    die "Working tree is not clean after Patch 007 commits."

  ok "Created six atomic Patch 007 commits."
}

push_feature_branch() {
  cd "$PROJECT_ROOT"
  git push -u origin "$FEATURE_BRANCH"

  printf '\n'
  ok "Patch 007 completed and pushed."
  printf 'Branch: %s\n' "$FEATURE_BRANCH"
  printf 'Head:   %s\n' "$(git rev-parse --short HEAD)"
  printf 'Base:   %s\n' "$BASE_BRANCH"
  printf '\nCommits:\n'
  git log --oneline "origin/$BASE_BRANCH..HEAD"
  printf '\nPull request:\n'
  printf 'https://github.com/prateushsharma/sentinel-fcc/compare/%s...%s?expand=1\n' \
    "$BASE_BRANCH" "$FEATURE_BRANCH"
  printf '\nNext stage: FCC ActionResult attestation verification and executor bridge.\n'
}

main() {
  require_command git
  require_command go
  require_command gofmt
  require_command forge
  require_command python3
  require_command shellcheck

  validate_and_create_branch

  cd "$PROJECT_ROOT"
  write_simulation_package
  modify_extension_for_simulation
  write_simulation_tests
  write_documentation
  archive_patch

  format_and_verify
  verify_change_set
  commit_atomic_history
  push_feature_branch
}

main "$@"
