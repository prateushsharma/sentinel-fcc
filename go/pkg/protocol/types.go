package protocol

import (
	"math/big"

	"github.com/ethereum/go-ethereum/common"
)

// PolicyEnvelope is the public, hashable envelope around a private policy.
//
// RulesHash commits to the canonical private rules representation.
// MetadataHash commits to optional encrypted/offchain metadata.
// ChainScopeHash commits to the policy's allowed chain set.
type PolicyEnvelope struct {
	ProtocolVersion uint16
	SchemaVersion   uint16
	PolicyID        common.Hash
	Owner           common.Address
	Account         common.Address
	PolicyVersion   uint64
	ValidAfter      uint64
	ValidUntil      uint64
	ChainScopeHash  common.Hash
	RulesHash       common.Hash
	MetadataHash    common.Hash
}

// TransactionIntent is the exact call proposed by an autonomous agent.
//
// ChainID and Value are uint256 values in the canonical Solidity encoding.
// Data is never encoded directly into the struct hash; its Keccak-256 digest is.
type TransactionIntent struct {
	ProtocolVersion uint16
	ChainID         *big.Int
	Executor        common.Address
	Account         common.Address
	Agent           common.Address
	Target          common.Address
	Value           *big.Int
	Data            []byte
	Nonce           uint64
	ValidAfter      uint64
	ValidUntil      uint64
}

// EvaluationRequest binds an authenticated request to an active policy and one
// exact transaction-intent hash.
type EvaluationRequest struct {
	ProtocolVersion  uint16
	RequestID        common.Hash
	PolicyID         common.Hash
	PolicyCommitment common.Hash
	PolicyVersion    uint64
	IntentHash       common.Hash
	RequestedAt      uint64
}

// FirewallDecision is the TEE-produced authorization payload consumed onchain.
//
// SimulationHash commits to normalized effects; raw traces remain confidential.
// RiskFlags is encoded as a Solidity uint256.
type FirewallDecision struct {
	ProtocolVersion       uint16
	DecisionVersion       uint16
	RequestID             common.Hash
	IntentHash            common.Hash
	PolicyID              common.Hash
	PolicyCommitment      common.Hash
	PolicyVersion         uint64
	ChainID               *big.Int
	Executor              common.Address
	Account               common.Address
	Agent                 common.Address
	Nonce                 uint64
	ValidAfter            uint64
	ValidUntil            uint64
	SimulationBlockNumber uint64
	SimulationBlockHash   common.Hash
	SimulationHash        common.Hash
	Approved              bool
	RiskScore             uint8
	RiskFlags             *big.Int
}
