// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ISentinelDecisionVerifier} from "./interfaces/ISentinelDecisionVerifier.sol";
import {ISentinelPolicyRegistry} from "./interfaces/ISentinelPolicyRegistry.sol";
import {SentinelProtocol} from "./libraries/SentinelProtocol.sol";

/// @title SentinelExecutor
/// @notice Replay-safe smart-account boundary for exact TEE-authorized calls.
contract SentinelExecutor {
    error InvalidRegistry();
    error InvalidVerifier();
    error InvalidSimulationWindow(uint64 supplied);
    error ReentrantExecution();
    error UnsupportedProtocolVersion(uint16 supplied);
    error UnsupportedDecisionVersion(uint16 supplied);
    error InvalidChainId();
    error InvalidExecutor();
    error InvalidAccount();
    error InvalidAgent();
    error InvalidTarget();
    error InvalidValidityWindow();
    error IntentNotCurrentlyValid();
    error DecisionNotCurrentlyValid();
    error DecisionNotApproved();
    error InvalidRiskScore(uint8 supplied);
    error IntentHashMismatch();
    error DecisionBindingMismatch();
    error PolicyInactive();
    error SimulationBlockNotHistorical(uint64 simulationBlock, uint256 currentBlock);
    error SimulationBlockStale(uint256 age, uint64 maximumAge);
    error SimulationBlockHashMismatch();
    error InvalidDecisionProof();
    error RequestAlreadyConsumed(bytes32 requestId);
    error DecisionAlreadyConsumed(bytes32 decisionHash);
    error UnexpectedNonce(address agent, uint64 expected, uint64 supplied);
    error NonceExhausted(address agent);

    event ExecutionAuthorized(
        bytes32 indexed requestId,
        bytes32 indexed decisionHash,
        bytes32 indexed intentHash,
        bytes32 policyId,
        address agent,
        address target,
        uint64 nonce
    );

    event ExecutionCompleted(
        bytes32 indexed requestId,
        bytes32 indexed decisionHash,
        address indexed target,
        uint256 value,
        bytes32 returnDataHash
    );

    bytes32 private constant _EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant _NAME_HASH = keccak256("SentinelFCC");
    bytes32 private constant _VERSION_HASH = keccak256("1");

    ISentinelPolicyRegistry public immutable policyRegistry;
    ISentinelDecisionVerifier public immutable decisionVerifier;
    uint64 public immutable maxSimulationBlockAge;

    mapping(address agent => uint64 nonce) public nextNonce;
    mapping(bytes32 requestId => bool consumed) public consumedRequestIds;
    mapping(bytes32 decisionHash => bool consumed) public consumedDecisionHashes;

    uint256 private _executionLock = 1;

    constructor(
        ISentinelPolicyRegistry policyRegistry_,
        ISentinelDecisionVerifier decisionVerifier_,
        uint64 maxSimulationBlockAge_
    ) {
        if (address(policyRegistry_) == address(0) || address(policyRegistry_).code.length == 0) {
            revert InvalidRegistry();
        }
        if (address(decisionVerifier_) == address(0) || address(decisionVerifier_).code.length == 0) {
            revert InvalidVerifier();
        }
        if (maxSimulationBlockAge_ == 0 || maxSimulationBlockAge_ > 255) {
            revert InvalidSimulationWindow(maxSimulationBlockAge_);
        }

        policyRegistry = policyRegistry_;
        decisionVerifier = decisionVerifier_;
        maxSimulationBlockAge = maxSimulationBlockAge_;
    }

    receive() external payable {}

    modifier nonReentrant() {
        if (_executionLock != 1) {
            revert ReentrantExecution();
        }
        _executionLock = 2;
        _;
        _executionLock = 1;
    }

    function domainSeparator() public view returns (bytes32) {
        return keccak256(abi.encode(_EIP712_DOMAIN_TYPEHASH, _NAME_HASH, _VERSION_HASH, block.chainid, address(this)));
    }

    function decisionDigest(SentinelProtocol.FirewallDecision memory decision) public view returns (bytes32) {
        bytes32 decisionHash = SentinelProtocol.hashFirewallDecision(decision);
        return keccak256(abi.encodePacked(hex"1901", domainSeparator(), decisionHash));
    }

    function execute(
        SentinelProtocol.TransactionIntent calldata intent,
        SentinelProtocol.FirewallDecision calldata decision,
        bytes calldata proof
    ) external nonReentrant returns (bytes memory returnData) {
        bytes32 intentHash = SentinelProtocol.hashTransactionIntent(intent);

        _validateIntent(intent);
        _validateDecisionBinding(intent, decision, intentHash);
        _validatePolicy(decision);
        _validateSimulation(decision);

        bytes32 decisionHash = SentinelProtocol.hashFirewallDecision(decision);
        _validateReplayState(decision, decisionHash, intent.nonce);

        bytes32 digest = keccak256(abi.encodePacked(hex"1901", domainSeparator(), decisionHash));
        if (!decisionVerifier.verifyDecision(digest, proof)) {
            revert InvalidDecisionProof();
        }

        _consumeReplayState(decision, decisionHash, intent.nonce);

        emit ExecutionAuthorized(
            decision.requestId, decisionHash, intentHash, decision.policyId, intent.agent, intent.target, intent.nonce
        );

        bool success;
        (success, returnData) = intent.target.call{value: intent.value}(intent.data);
        if (!success) {
            _revertWithReturnData(returnData);
        }

        emit ExecutionCompleted(decision.requestId, decisionHash, intent.target, intent.value, keccak256(returnData));
    }

    function _validateIntent(SentinelProtocol.TransactionIntent calldata intent) private view {
        if (intent.protocolVersion != SentinelProtocol.currentProtocolVersion()) {
            revert UnsupportedProtocolVersion(intent.protocolVersion);
        }
        if (intent.chainId != block.chainid) {
            revert InvalidChainId();
        }
        if (intent.executor != address(this)) {
            revert InvalidExecutor();
        }
        if (intent.account != address(this)) {
            revert InvalidAccount();
        }
        if (intent.agent == address(0)) {
            revert InvalidAgent();
        }
        if (intent.target == address(0)) {
            revert InvalidTarget();
        }
        if (intent.validUntil == 0 || intent.validAfter > intent.validUntil) {
            revert InvalidValidityWindow();
        }
        if (block.timestamp < intent.validAfter || block.timestamp > intent.validUntil) {
            revert IntentNotCurrentlyValid();
        }
    }

    function _validateDecisionBinding(
        SentinelProtocol.TransactionIntent calldata intent,
        SentinelProtocol.FirewallDecision calldata decision,
        bytes32 intentHash
    ) private view {
        if (decision.protocolVersion != SentinelProtocol.currentProtocolVersion()) {
            revert UnsupportedProtocolVersion(decision.protocolVersion);
        }
        if (decision.decisionVersion != SentinelProtocol.currentDecisionVersion()) {
            revert UnsupportedDecisionVersion(decision.decisionVersion);
        }
        if (!decision.approved) {
            revert DecisionNotApproved();
        }
        if (decision.riskScore > 100) {
            revert InvalidRiskScore(decision.riskScore);
        }
        if (decision.requestId == bytes32(0) || decision.policyId == bytes32(0)) {
            revert DecisionBindingMismatch();
        }
        if (decision.intentHash != intentHash) {
            revert IntentHashMismatch();
        }
        if (decision.chainId != intent.chainId || decision.executor != intent.executor) {
            revert DecisionBindingMismatch();
        }
        if (decision.account != intent.account || decision.agent != intent.agent || decision.nonce != intent.nonce) {
            revert DecisionBindingMismatch();
        }
        if (
            decision.validAfter != intent.validAfter || decision.validUntil != intent.validUntil
                || decision.validUntil == 0 || decision.validAfter > decision.validUntil
        ) {
            revert DecisionBindingMismatch();
        }
        if (block.timestamp < decision.validAfter || block.timestamp > decision.validUntil) {
            revert DecisionNotCurrentlyValid();
        }
    }

    function _validatePolicy(SentinelProtocol.FirewallDecision calldata decision) private view {
        bool active = policyRegistry.isPolicyActive(
            decision.policyId, decision.policyCommitment, address(this), decision.policyVersion, block.timestamp
        );
        if (!active) {
            revert PolicyInactive();
        }
    }

    function _validateSimulation(SentinelProtocol.FirewallDecision calldata decision) private view {
        uint256 simulationBlock = decision.simulationBlockNumber;
        if (simulationBlock >= block.number) {
            revert SimulationBlockNotHistorical(decision.simulationBlockNumber, block.number);
        }

        uint256 age = block.number - simulationBlock;
        if (age > maxSimulationBlockAge) {
            revert SimulationBlockStale(age, maxSimulationBlockAge);
        }

        bytes32 canonicalBlockHash = blockhash(simulationBlock);
        if (canonicalBlockHash == bytes32(0) || canonicalBlockHash != decision.simulationBlockHash) {
            revert SimulationBlockHashMismatch();
        }
    }

    function _validateReplayState(
        SentinelProtocol.FirewallDecision calldata decision,
        bytes32 decisionHash,
        uint64 suppliedNonce
    ) private view {
        if (consumedRequestIds[decision.requestId]) {
            revert RequestAlreadyConsumed(decision.requestId);
        }
        if (consumedDecisionHashes[decisionHash]) {
            revert DecisionAlreadyConsumed(decisionHash);
        }

        uint64 expectedNonce = nextNonce[decision.agent];
        if (suppliedNonce != expectedNonce) {
            revert UnexpectedNonce(decision.agent, expectedNonce, suppliedNonce);
        }
        if (expectedNonce == type(uint64).max) {
            revert NonceExhausted(decision.agent);
        }
    }

    function _consumeReplayState(
        SentinelProtocol.FirewallDecision calldata decision,
        bytes32 decisionHash,
        uint64 nonce
    ) private {
        consumedRequestIds[decision.requestId] = true;
        consumedDecisionHashes[decisionHash] = true;
        nextNonce[decision.agent] = nonce + 1;
    }

    function _revertWithReturnData(bytes memory returnData) private pure {
        assembly ("memory-safe") {
            revert(add(returnData, 32), mload(returnData))
        }
    }
}
