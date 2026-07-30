// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {SentinelExecutor} from "../contracts/SentinelExecutor.sol";
import {SentinelPolicyRegistry} from "../contracts/SentinelPolicyRegistry.sol";
import {ISentinelDecisionVerifier} from "../contracts/interfaces/ISentinelDecisionVerifier.sol";
import {SentinelProtocol} from "../contracts/libraries/SentinelProtocol.sol";

interface VmExecutor {
    function warp(uint256 timestamp) external;
    function roll(uint256 blockNumber) external;
    function setBlockhash(uint256 blockNumber, bytes32 blockHash) external;
    function prank(address sender) external;
    function expectRevert(bytes4 revertData) external;
    function expectRevert(bytes calldata revertData) external;
    function deal(address account, uint256 balance) external;
}

contract MockDecisionVerifier is ISentinelDecisionVerifier {
    bool public result = true;

    function setResult(bool result_) external {
        result = result_;
    }

    function verifyDecision(bytes32, bytes calldata) external view returns (bool) {
        return result;
    }
}

contract SentinelExecutionTarget {
    error TargetFailure();

    uint256 public value;

    function setValue(uint256 value_) external payable returns (uint256) {
        value = value_;
        return value_ + 1;
    }

    function fail() external pure {
        revert TargetFailure();
    }
}

contract SentinelExecutorTest {
    VmExecutor private constant vm = VmExecutor(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint64 private constant NOW = 2_000_000_000;
    uint64 private constant SIMULATION_BLOCK = 999;
    bytes32 private constant SIMULATION_BLOCK_HASH = keccak256("simulation-block");
    bytes32 private constant POLICY_ID = keccak256("executor-policy");

    address private constant OWNER = address(0xA11CE);
    address private constant AGENT = address(0xA6E17);

    SentinelPolicyRegistry private registry;
    MockDecisionVerifier private verifier;
    SentinelExecutor private executor;
    SentinelExecutionTarget private target;
    bytes32 private policyCommitment;

    function setUp() public {
        vm.warp(NOW);
        vm.roll(1_000);
        vm.setBlockhash(SIMULATION_BLOCK, SIMULATION_BLOCK_HASH);

        registry = new SentinelPolicyRegistry();
        verifier = new MockDecisionVerifier();
        executor = new SentinelExecutor(registry, verifier, 64);
        target = new SentinelExecutionTarget();

        SentinelProtocol.PolicyEnvelope memory policy = _policy();
        vm.prank(OWNER);
        policyCommitment = registry.registerPolicy(policy);

        vm.deal(address(executor), 10 ether);
    }

    function testExecutesExactAuthorizedIntent() public {
        SentinelProtocol.TransactionIntent memory intent = _intent(0);
        SentinelProtocol.FirewallDecision memory decision = _decision(intent, keccak256("request-1"));

        bytes memory returnData = executor.execute(intent, decision, hex"01");

        require(target.value() == 77, "target state not updated");
        require(abi.decode(returnData, (uint256)) == 78, "return data mismatch");
        require(executor.nextNonce(AGENT) == 1, "nonce not consumed");
        require(executor.consumedRequestIds(decision.requestId), "request not consumed");
    }

    function testRequestCannotReplay() public {
        SentinelProtocol.TransactionIntent memory intent = _intent(0);
        SentinelProtocol.FirewallDecision memory decision = _decision(intent, keccak256("request-2"));

        executor.execute(intent, decision, hex"01");

        vm.expectRevert(abi.encodeWithSelector(SentinelExecutor.RequestAlreadyConsumed.selector, decision.requestId));
        executor.execute(intent, decision, hex"01");
    }

    function testUnexpectedNonceRejected() public {
        SentinelProtocol.TransactionIntent memory intent = _intent(3);
        SentinelProtocol.FirewallDecision memory decision = _decision(intent, keccak256("request-3"));

        vm.expectRevert(abi.encodeWithSelector(SentinelExecutor.UnexpectedNonce.selector, AGENT, uint64(0), uint64(3)));
        executor.execute(intent, decision, hex"01");
    }

    function testIntentMutationBreaksDecisionBinding() public {
        SentinelProtocol.TransactionIntent memory intent = _intent(0);
        SentinelProtocol.FirewallDecision memory decision = _decision(intent, keccak256("request-4"));
        intent.data = abi.encodeWithSelector(target.setValue.selector, 999);

        vm.expectRevert(SentinelExecutor.IntentHashMismatch.selector);
        executor.execute(intent, decision, hex"01");
    }

    function testStaleSimulationRejected() public {
        SentinelProtocol.TransactionIntent memory intent = _intent(0);
        SentinelProtocol.FirewallDecision memory decision = _decision(intent, keccak256("request-5"));

        vm.roll(1_100);
        vm.expectRevert(
            abi.encodeWithSelector(SentinelExecutor.SimulationBlockStale.selector, uint256(101), uint64(64))
        );
        executor.execute(intent, decision, hex"01");
    }

    function testInvalidProofRejected() public {
        SentinelProtocol.TransactionIntent memory intent = _intent(0);
        SentinelProtocol.FirewallDecision memory decision = _decision(intent, keccak256("request-6"));
        verifier.setResult(false);

        vm.expectRevert(SentinelExecutor.InvalidDecisionProof.selector);
        executor.execute(intent, decision, hex"01");
    }

    function testRevokedPolicyRejected() public {
        SentinelProtocol.TransactionIntent memory intent = _intent(0);
        SentinelProtocol.FirewallDecision memory decision = _decision(intent, keccak256("request-7"));

        vm.prank(OWNER);
        registry.revokePolicy(POLICY_ID);

        vm.expectRevert(SentinelExecutor.PolicyInactive.selector);
        executor.execute(intent, decision, hex"01");
    }

    function testTargetRevertDoesNotConsumeReplayState() public {
        SentinelProtocol.TransactionIntent memory intent = _intent(0);
        intent.data = abi.encodeWithSelector(target.fail.selector);
        SentinelProtocol.FirewallDecision memory decision = _decision(intent, keccak256("request-8"));

        vm.expectRevert(SentinelExecutionTarget.TargetFailure.selector);
        executor.execute(intent, decision, hex"01");

        require(executor.nextNonce(AGENT) == 0, "nonce consumed after reverted target");
        require(!executor.consumedRequestIds(decision.requestId), "request consumed after revert");
    }

    function _policy() private view returns (SentinelProtocol.PolicyEnvelope memory policy) {
        policy.protocolVersion = 1;
        policy.schemaVersion = 1;
        policy.policyId = POLICY_ID;
        policy.owner = OWNER;
        policy.account = address(executor);
        policy.policyVersion = 1;
        policy.validAfter = NOW - 100;
        policy.validUntil = NOW + 10_000;
        policy.chainScopeHash = keccak256(abi.encode(block.chainid));
        policy.rulesHash = keccak256("executor-rules");
        policy.metadataHash = keccak256("executor-metadata");
    }

    function _intent(uint64 nonce) private view returns (SentinelProtocol.TransactionIntent memory intent) {
        intent.protocolVersion = 1;
        intent.chainId = block.chainid;
        intent.executor = address(executor);
        intent.account = address(executor);
        intent.agent = AGENT;
        intent.target = address(target);
        intent.value = 0;
        intent.data = abi.encodeWithSelector(target.setValue.selector, 77);
        intent.nonce = nonce;
        intent.validAfter = NOW - 10;
        intent.validUntil = NOW + 1_000;
    }

    function _decision(SentinelProtocol.TransactionIntent memory intent, bytes32 requestId)
        private
        view
        returns (SentinelProtocol.FirewallDecision memory decision)
    {
        decision.protocolVersion = 1;
        decision.decisionVersion = 1;
        decision.requestId = requestId;
        decision.intentHash = SentinelProtocol.hashTransactionIntent(intent);
        decision.policyId = POLICY_ID;
        decision.policyCommitment = policyCommitment;
        decision.policyVersion = 1;
        decision.chainId = intent.chainId;
        decision.executor = intent.executor;
        decision.account = intent.account;
        decision.agent = intent.agent;
        decision.nonce = intent.nonce;
        decision.validAfter = intent.validAfter;
        decision.validUntil = intent.validUntil;
        decision.simulationBlockNumber = SIMULATION_BLOCK;
        decision.simulationBlockHash = SIMULATION_BLOCK_HASH;
        decision.simulationHash = keccak256("normalized-effects");
        decision.approved = true;
        decision.riskScore = 12;
        decision.riskFlags = 0;
    }
}
