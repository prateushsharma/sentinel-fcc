// Package simulation obtains deterministic, quorum-checked EVM call effects.
package simulation

import (
	"context"
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
