package protocol

import (
	"fmt"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
)

const (
	policyTypeString   = "SentinelPolicy(uint16 protocolVersion,uint16 schemaVersion,bytes32 policyId,address owner,address account,uint64 policyVersion,uint64 validAfter,uint64 validUntil,bytes32 chainScopeHash,bytes32 rulesHash,bytes32 metadataHash)"
	intentTypeString   = "SentinelTransactionIntent(uint16 protocolVersion,uint256 chainId,address executor,address account,address agent,address target,uint256 value,bytes32 calldataHash,uint64 nonce,uint64 validAfter,uint64 validUntil)"
	requestTypeString  = "SentinelEvaluationRequest(uint16 protocolVersion,bytes32 requestId,bytes32 policyId,bytes32 policyCommitment,uint64 policyVersion,bytes32 intentHash,uint64 requestedAt)"
	decisionTypeString = "SentinelFirewallDecision(uint16 protocolVersion,uint16 decisionVersion,bytes32 requestId,bytes32 intentHash,bytes32 policyId,bytes32 policyCommitment,uint64 policyVersion,uint256 chainId,address executor,address account,address agent,uint64 nonce,uint64 validAfter,uint64 validUntil,uint64 simulationBlockNumber,bytes32 simulationBlockHash,bytes32 simulationHash,bool approved,uint8 riskScore,uint256 riskFlags)"
)

var (
	policyTypeHash   = crypto.Keccak256Hash([]byte(policyTypeString))
	intentTypeHash   = crypto.Keccak256Hash([]byte(intentTypeString))
	requestTypeHash  = crypto.Keccak256Hash([]byte(requestTypeString))
	decisionTypeHash = crypto.Keccak256Hash([]byte(decisionTypeString))

	abiBytes32 = mustABIType("bytes32")
	abiUint16  = mustABIType("uint16")
	abiUint64  = mustABIType("uint64")
	abiUint8   = mustABIType("uint8")
	abiUint256 = mustABIType("uint256")
	abiAddress = mustABIType("address")
	abiBool    = mustABIType("bool")

	policyArguments = abi.Arguments{
		{Type: abiBytes32},
		{Type: abiUint16},
		{Type: abiUint16},
		{Type: abiBytes32},
		{Type: abiAddress},
		{Type: abiAddress},
		{Type: abiUint64},
		{Type: abiUint64},
		{Type: abiUint64},
		{Type: abiBytes32},
		{Type: abiBytes32},
		{Type: abiBytes32},
	}

	intentArguments = abi.Arguments{
		{Type: abiBytes32},
		{Type: abiUint16},
		{Type: abiUint256},
		{Type: abiAddress},
		{Type: abiAddress},
		{Type: abiAddress},
		{Type: abiAddress},
		{Type: abiUint256},
		{Type: abiBytes32},
		{Type: abiUint64},
		{Type: abiUint64},
		{Type: abiUint64},
	}

	requestArguments = abi.Arguments{
		{Type: abiBytes32},
		{Type: abiUint16},
		{Type: abiBytes32},
		{Type: abiBytes32},
		{Type: abiBytes32},
		{Type: abiUint64},
		{Type: abiBytes32},
		{Type: abiUint64},
	}

	decisionArguments = abi.Arguments{
		{Type: abiBytes32},
		{Type: abiUint16},
		{Type: abiUint16},
		{Type: abiBytes32},
		{Type: abiBytes32},
		{Type: abiBytes32},
		{Type: abiBytes32},
		{Type: abiUint64},
		{Type: abiUint256},
		{Type: abiAddress},
		{Type: abiAddress},
		{Type: abiAddress},
		{Type: abiUint64},
		{Type: abiUint64},
		{Type: abiUint64},
		{Type: abiUint64},
		{Type: abiBytes32},
		{Type: abiBytes32},
		{Type: abiBool},
		{Type: abiUint8},
		{Type: abiUint256},
	}
)

func mustABIType(name string) abi.Type {
	value, err := abi.NewType(name, "", nil)
	if err != nil {
		panic(fmt.Sprintf("create ABI type %q: %v", name, err))
	}
	return value
}

func hashPacked(arguments abi.Arguments, values ...any) (common.Hash, error) {
	encoded, err := arguments.Pack(values...)
	if err != nil {
		return common.Hash{}, fmt.Errorf("ABI-pack canonical protocol value: %w", err)
	}
	return crypto.Keccak256Hash(encoded), nil
}

// PolicyTypeHash returns the canonical SentinelPolicy type hash.
func PolicyTypeHash() common.Hash {
	return policyTypeHash
}

// TransactionIntentTypeHash returns the canonical intent type hash.
func TransactionIntentTypeHash() common.Hash {
	return intentTypeHash
}

// EvaluationRequestTypeHash returns the canonical request type hash.
func EvaluationRequestTypeHash() common.Hash {
	return requestTypeHash
}

// FirewallDecisionTypeHash returns the canonical decision type hash.
func FirewallDecisionTypeHash() common.Hash {
	return decisionTypeHash
}

// CalldataHash returns Keccak-256 over raw EVM calldata.
func CalldataHash(data []byte) common.Hash {
	return crypto.Keccak256Hash(data)
}

// HashPolicyEnvelope returns the canonical Solidity-compatible policy commitment.
func HashPolicyEnvelope(policy PolicyEnvelope) (common.Hash, error) {
	if err := ValidatePolicyEnvelope(policy); err != nil {
		return common.Hash{}, err
	}
	return hashPacked(
		policyArguments,
		policyTypeHash,
		policy.ProtocolVersion,
		policy.SchemaVersion,
		policy.PolicyID,
		policy.Owner,
		policy.Account,
		policy.PolicyVersion,
		policy.ValidAfter,
		policy.ValidUntil,
		policy.ChainScopeHash,
		policy.RulesHash,
		policy.MetadataHash,
	)
}

// HashTransactionIntent returns the canonical Solidity-compatible intent hash.
func HashTransactionIntent(intent TransactionIntent) (common.Hash, error) {
	if err := ValidateTransactionIntent(intent); err != nil {
		return common.Hash{}, err
	}
	return hashPacked(
		intentArguments,
		intentTypeHash,
		intent.ProtocolVersion,
		intent.ChainID,
		intent.Executor,
		intent.Account,
		intent.Agent,
		intent.Target,
		intent.Value,
		CalldataHash(intent.Data),
		intent.Nonce,
		intent.ValidAfter,
		intent.ValidUntil,
	)
}

// HashEvaluationRequest returns the canonical Solidity-compatible request hash.
func HashEvaluationRequest(request EvaluationRequest) (common.Hash, error) {
	if err := ValidateEvaluationRequest(request); err != nil {
		return common.Hash{}, err
	}
	return hashPacked(
		requestArguments,
		requestTypeHash,
		request.ProtocolVersion,
		request.RequestID,
		request.PolicyID,
		request.PolicyCommitment,
		request.PolicyVersion,
		request.IntentHash,
		request.RequestedAt,
	)
}

// HashFirewallDecision returns the canonical Solidity-compatible decision hash.
func HashFirewallDecision(decision FirewallDecision) (common.Hash, error) {
	if err := ValidateFirewallDecision(decision); err != nil {
		return common.Hash{}, err
	}
	return hashPacked(
		decisionArguments,
		decisionTypeHash,
		decision.ProtocolVersion,
		decision.DecisionVersion,
		decision.RequestID,
		decision.IntentHash,
		decision.PolicyID,
		decision.PolicyCommitment,
		decision.PolicyVersion,
		decision.ChainID,
		decision.Executor,
		decision.Account,
		decision.Agent,
		decision.Nonce,
		decision.ValidAfter,
		decision.ValidUntil,
		decision.SimulationBlockNumber,
		decision.SimulationBlockHash,
		decision.SimulationHash,
		decision.Approved,
		decision.RiskScore,
		decision.RiskFlags,
	)
}
