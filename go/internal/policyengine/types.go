package policyengine

import (
	"extension-scaffold/pkg/policy"
	"extension-scaffold/pkg/protocol"

	"github.com/ethereum/go-ethereum/common"
)

// SimulationSnapshot is a deterministic, normalized simulation observation.
//
// A later provider layer will obtain and quorum-check these values. The engine
// consumes only this normalized representation.
type SimulationSnapshot struct {
	IntentHash          common.Hash
	BlockNumber         uint64
	BlockHash           common.Hash
	ObservedBlockNumber uint64
	EffectsHash         common.Hash
	Success             bool
	ProviderAgreement   bool
	TargetCodeHash      common.Hash
}

// Request contains every input needed for deterministic policy evaluation.
type Request struct {
	RequestID      common.Hash
	EvaluationTime uint64
	PolicyEnvelope protocol.PolicyEnvelope
	PrivatePolicy  policy.PrivatePolicy
	Intent         protocol.TransactionIntent
	Simulation     SimulationSnapshot
}

// Result contains the exact executor decision and stable explanations.
type Result struct {
	Decision         protocol.FirewallDecision
	DecisionHash     common.Hash
	PolicyCommitment common.Hash
	RulesHash        common.Hash
	ChainScopeHash   common.Hash
	Reasons          []string
}
