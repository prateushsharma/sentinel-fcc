// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @title SentinelProtocol
/// @notice Versioned canonical structs and hashing for SentinelFCC.
/// @dev These are struct hashes, not final EIP-712 signing digests.
library SentinelProtocol {
    uint16 internal constant CURRENT_PROTOCOL_VERSION = 1;
    uint16 internal constant CURRENT_POLICY_SCHEMA_VERSION = 1;
    uint16 internal constant CURRENT_DECISION_VERSION = 1;

    bytes32 internal constant POLICY_TYPEHASH = keccak256(
        "SentinelPolicy(uint16 protocolVersion,uint16 schemaVersion,bytes32 policyId,address owner,address account,uint64 policyVersion,uint64 validAfter,uint64 validUntil,bytes32 chainScopeHash,bytes32 rulesHash,bytes32 metadataHash)"
    );

    bytes32 internal constant TRANSACTION_INTENT_TYPEHASH = keccak256(
        "SentinelTransactionIntent(uint16 protocolVersion,uint256 chainId,address executor,address account,address agent,address target,uint256 value,bytes32 calldataHash,uint64 nonce,uint64 validAfter,uint64 validUntil)"
    );

    bytes32 internal constant EVALUATION_REQUEST_TYPEHASH = keccak256(
        "SentinelEvaluationRequest(uint16 protocolVersion,bytes32 requestId,bytes32 policyId,bytes32 policyCommitment,uint64 policyVersion,bytes32 intentHash,uint64 requestedAt)"
    );

    bytes32 internal constant FIREWALL_DECISION_TYPEHASH = keccak256(
        "SentinelFirewallDecision(uint16 protocolVersion,uint16 decisionVersion,bytes32 requestId,bytes32 intentHash,bytes32 policyId,bytes32 policyCommitment,uint64 policyVersion,uint256 chainId,address executor,address account,address agent,uint64 nonce,uint64 validAfter,uint64 validUntil,uint64 simulationBlockNumber,bytes32 simulationBlockHash,bytes32 simulationHash,bool approved,uint8 riskScore,uint256 riskFlags)"
    );

    uint8 internal constant RISK_UNKNOWN_TARGET = 0;
    uint8 internal constant RISK_SELECTOR_NOT_ALLOWED = 1;
    uint8 internal constant RISK_UNLIMITED_APPROVAL = 2;
    uint8 internal constant RISK_APPROVAL_TOO_LARGE = 3;
    uint8 internal constant RISK_TRANSFER_TOO_LARGE = 4;
    uint8 internal constant RISK_RECIPIENT_NOT_ALLOWED = 5;
    uint8 internal constant RISK_SIMULATION_FAILED = 6;
    uint8 internal constant RISK_SIMULATION_STALE = 7;
    uint8 internal constant RISK_PROVIDER_DISAGREEMENT = 8;
    uint8 internal constant RISK_MALFORMED_CALLDATA = 9;
    uint8 internal constant RISK_UNSUPPORTED_OPERATION = 10;
    uint8 internal constant RISK_POLICY_MISSING = 11;
    uint8 internal constant RISK_POLICY_REVOKED = 12;
    uint8 internal constant RISK_AGENT_UNAUTHORIZED = 13;
    uint8 internal constant RISK_REQUEST_EXPIRED = 14;
    uint8 internal constant RISK_NONCE_REUSED = 15;
    uint8 internal constant RISK_CODE_HASH_MISMATCH = 16;
    uint8 internal constant RISK_NESTED_CALL_OPAQUE = 17;

    struct PolicyEnvelope {
        uint16 protocolVersion;
        uint16 schemaVersion;
        bytes32 policyId;
        address owner;
        address account;
        uint64 policyVersion;
        uint64 validAfter;
        uint64 validUntil;
        bytes32 chainScopeHash;
        bytes32 rulesHash;
        bytes32 metadataHash;
    }

    struct TransactionIntent {
        uint16 protocolVersion;
        uint256 chainId;
        address executor;
        address account;
        address agent;
        address target;
        uint256 value;
        bytes data;
        uint64 nonce;
        uint64 validAfter;
        uint64 validUntil;
    }

    struct EvaluationRequest {
        uint16 protocolVersion;
        bytes32 requestId;
        bytes32 policyId;
        bytes32 policyCommitment;
        uint64 policyVersion;
        bytes32 intentHash;
        uint64 requestedAt;
    }

    struct FirewallDecision {
        uint16 protocolVersion;
        uint16 decisionVersion;
        bytes32 requestId;
        bytes32 intentHash;
        bytes32 policyId;
        bytes32 policyCommitment;
        uint64 policyVersion;
        uint256 chainId;
        address executor;
        address account;
        address agent;
        uint64 nonce;
        uint64 validAfter;
        uint64 validUntil;
        uint64 simulationBlockNumber;
        bytes32 simulationBlockHash;
        bytes32 simulationHash;
        bool approved;
        uint8 riskScore;
        uint256 riskFlags;
    }

    function policyTypeHash() internal pure returns (bytes32) {
        return POLICY_TYPEHASH;
    }

    function transactionIntentTypeHash() internal pure returns (bytes32) {
        return TRANSACTION_INTENT_TYPEHASH;
    }

    function evaluationRequestTypeHash() internal pure returns (bytes32) {
        return EVALUATION_REQUEST_TYPEHASH;
    }

    function firewallDecisionTypeHash() internal pure returns (bytes32) {
        return FIREWALL_DECISION_TYPEHASH;
    }

    function riskMask(uint8 flag) internal pure returns (uint256) {
        require(flag <= RISK_NESTED_CALL_OPAQUE, "unknown risk flag");
        return uint256(1) << flag;
    }

    function hashPolicyEnvelope(PolicyEnvelope memory policy) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                POLICY_TYPEHASH,
                policy.protocolVersion,
                policy.schemaVersion,
                policy.policyId,
                policy.owner,
                policy.account,
                policy.policyVersion,
                policy.validAfter,
                policy.validUntil,
                policy.chainScopeHash,
                policy.rulesHash,
                policy.metadataHash
            )
        );
    }

    function calldataHash(bytes memory data) internal pure returns (bytes32) {
        return keccak256(data);
    }

    function hashTransactionIntent(TransactionIntent memory intent) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                TRANSACTION_INTENT_TYPEHASH,
                intent.protocolVersion,
                intent.chainId,
                intent.executor,
                intent.account,
                intent.agent,
                intent.target,
                intent.value,
                calldataHash(intent.data),
                intent.nonce,
                intent.validAfter,
                intent.validUntil
            )
        );
    }

    function hashEvaluationRequest(EvaluationRequest memory request) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                EVALUATION_REQUEST_TYPEHASH,
                request.protocolVersion,
                request.requestId,
                request.policyId,
                request.policyCommitment,
                request.policyVersion,
                request.intentHash,
                request.requestedAt
            )
        );
    }

    function hashFirewallDecision(FirewallDecision memory decision) internal pure returns (bytes32) {
        // FirewallDecision is entirely static. ABI-encoding the struct yields
        // the same ordered words as encoding each field individually, while
        // avoiding compiler stack pressure from twenty separate arguments.
        bytes memory encodedDecision = abi.encode(decision);
        return keccak256(bytes.concat(FIREWALL_DECISION_TYPEHASH, encodedDecision));
    }
}
