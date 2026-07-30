// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {SentinelProtocol} from "../contracts/libraries/SentinelProtocol.sol";

contract SentinelProtocolHashingTest {
    bytes32 private constant EXPECTED_POLICY_TYPEHASH =
        0x34715d88a63fe1d21b6ea7c7ba9a536db498f3f159bd31fb9848c65894420f97;
    bytes32 private constant EXPECTED_INTENT_TYPEHASH =
        0x845377ffaa3393a7966abee60e72e96769548533706bd1eb08a119d050bc2950;
    bytes32 private constant EXPECTED_REQUEST_TYPEHASH =
        0xf39ac6e0a9a200ca84e19c74a2841c667e7f0bace9c8e7e817cb7429632a2eba;
    bytes32 private constant EXPECTED_DECISION_TYPEHASH =
        0xc57d2d7acdac6b5baeaa6153bb6cc6fca7e78351773e88dfd197288f09f1a375;

    bytes32 private constant EXPECTED_POLICY_COMMITMENT =
        0x920969b2945d0f5f6e97d0f49504d7a7ab9b5bba1d9bb4169f1ed0063264d8d6;
    bytes32 private constant EXPECTED_CALLDATA_HASH =
        0xba8be884dc1b2bcbae9cbc76531f512dbee5e5231e4799a8791e782eca0c2801;
    bytes32 private constant EXPECTED_INTENT_HASH = 0x28abb7ea9e331dd76828eeeb29a56bba8d0e5ac2022104ffb321ccb49df9e816;
    bytes32 private constant EXPECTED_REQUEST_HASH = 0x3b1b9bcad2773155238ae26898f7d5191377289136aee2606b0040e182f5b3bc;
    bytes32 private constant EXPECTED_DECISION_HASH =
        0xdae8957633a9e6c762bd4b04cc3613698c0e3755699c7c8c0412fc84ba3a9fc8;

    function testTypeHashesMatchGoVector() public pure {
        require(SentinelProtocol.policyTypeHash() == EXPECTED_POLICY_TYPEHASH, "policy typehash");
        require(SentinelProtocol.transactionIntentTypeHash() == EXPECTED_INTENT_TYPEHASH, "intent typehash");
        require(SentinelProtocol.evaluationRequestTypeHash() == EXPECTED_REQUEST_TYPEHASH, "request typehash");
        require(SentinelProtocol.firewallDecisionTypeHash() == EXPECTED_DECISION_TYPEHASH, "decision typehash");
    }

    function testPolicyCommitmentMatchesGoVector() public pure {
        SentinelProtocol.PolicyEnvelope memory policy = _policy();
        require(SentinelProtocol.hashPolicyEnvelope(policy) == EXPECTED_POLICY_COMMITMENT, "policy hash");
    }

    function testIntentHashMatchesGoVector() public pure {
        SentinelProtocol.TransactionIntent memory intent = _intent();
        require(SentinelProtocol.calldataHash(intent.data) == EXPECTED_CALLDATA_HASH, "calldata hash");
        require(SentinelProtocol.hashTransactionIntent(intent) == EXPECTED_INTENT_HASH, "intent hash");
    }

    function testRequestHashMatchesGoVector() public pure {
        SentinelProtocol.EvaluationRequest memory request = SentinelProtocol.EvaluationRequest({
            protocolVersion: 1,
            requestId: 0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee,
            policyId: 0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa,
            policyCommitment: EXPECTED_POLICY_COMMITMENT,
            policyVersion: 7,
            intentHash: EXPECTED_INTENT_HASH,
            requestedAt: 1_800_000_120
        });

        require(SentinelProtocol.hashEvaluationRequest(request) == EXPECTED_REQUEST_HASH, "request hash");
    }

    function testDecisionHashMatchesGoVector() public pure {
        SentinelProtocol.FirewallDecision memory decision = _decision();
        require(SentinelProtocol.hashFirewallDecision(decision) == EXPECTED_DECISION_HASH, "decision hash");
    }

    function testIntentMutationChangesHash() public pure {
        SentinelProtocol.TransactionIntent memory intent = _intent();
        bytes32 originalHash = SentinelProtocol.hashTransactionIntent(intent);
        intent.nonce += 1;
        require(SentinelProtocol.hashTransactionIntent(intent) != originalHash, "nonce not bound");
    }

    function _decision() private pure returns (SentinelProtocol.FirewallDecision memory decision) {
        decision.protocolVersion = 1;
        decision.decisionVersion = 1;
        decision.requestId = 0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee;
        decision.intentHash = EXPECTED_INTENT_HASH;
        decision.policyId = 0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;
        decision.policyCommitment = EXPECTED_POLICY_COMMITMENT;
        decision.policyVersion = 7;
        decision.chainId = 114;
        decision.executor = address(0x4444444444444444444444444444444444444444);
        decision.account = address(0x2222222222222222222222222222222222222222);
        decision.agent = address(0x3333333333333333333333333333333333333333);
        decision.nonce = 42;
        decision.validAfter = 1_800_000_100;
        decision.validUntil = 1_800_000_700;
        decision.simulationBlockNumber = 12_345_678;
        decision.simulationBlockHash = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;
        decision.simulationHash = 0x9999999999999999999999999999999999999999999999999999999999999999;
        decision.approved = false;
        decision.riskScore = 98;
        decision.riskFlags = SentinelProtocol.riskMask(0) | SentinelProtocol.riskMask(2);
    }

    function _policy() private pure returns (SentinelProtocol.PolicyEnvelope memory) {
        return SentinelProtocol.PolicyEnvelope({
            protocolVersion: 1,
            schemaVersion: 1,
            policyId: 0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa,
            owner: address(0x1111111111111111111111111111111111111111),
            account: address(0x2222222222222222222222222222222222222222),
            policyVersion: 7,
            validAfter: 1_800_000_000,
            validUntil: 1_800_086_400,
            chainScopeHash: 0xdddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd,
            rulesHash: 0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb,
            metadataHash: 0xcccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
        });
    }

    function _intent() private pure returns (SentinelProtocol.TransactionIntent memory) {
        return SentinelProtocol.TransactionIntent({
            protocolVersion: 1,
            chainId: 114,
            executor: address(0x4444444444444444444444444444444444444444),
            account: address(0x2222222222222222222222222222222222222222),
            agent: address(0x3333333333333333333333333333333333333333),
            target: address(0x5555555555555555555555555555555555555555),
            value: 0,
            data: hex"095ea7b300000000000000000000000066666666666666666666666666666666666666660000000000000000000000000000000000000000000000000000000005f5e100",
            nonce: 42,
            validAfter: 1_800_000_100,
            validUntil: 1_800_000_700
        });
    }
}
