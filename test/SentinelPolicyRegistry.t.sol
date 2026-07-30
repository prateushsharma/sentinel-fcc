// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {SentinelPolicyRegistry} from "../contracts/SentinelPolicyRegistry.sol";
import {ISentinelPolicyRegistry} from "../contracts/interfaces/ISentinelPolicyRegistry.sol";
import {SentinelProtocol} from "../contracts/libraries/SentinelProtocol.sol";

interface VmPolicyRegistry {
    function prank(address sender) external;
    function expectRevert(bytes4 revertData) external;
    function expectRevert(bytes calldata revertData) external;
}

contract SentinelPolicyRegistryTest {
    VmPolicyRegistry private constant vm = VmPolicyRegistry(address(uint160(uint256(keccak256("hevm cheat code")))));

    address private constant OWNER = address(0xA11CE);
    address private constant ACCOUNT = address(0xBEEF);
    bytes32 private constant POLICY_ID = keccak256("sentinel-policy-registry-test");

    SentinelPolicyRegistry private registry;

    function setUp() public {
        registry = new SentinelPolicyRegistry();
    }

    function testOwnerRegistersPolicyCommitment() public {
        SentinelProtocol.PolicyEnvelope memory policy = _policy(1);

        vm.prank(OWNER);
        bytes32 commitment = registry.registerPolicy(policy);

        require(commitment == SentinelProtocol.hashPolicyEnvelope(policy), "commitment mismatch");

        ISentinelPolicyRegistry.PolicyRecord memory stored = registry.getPolicy(POLICY_ID);
        require(stored.owner == OWNER, "owner mismatch");
        require(stored.account == ACCOUNT, "account mismatch");
        require(stored.commitment == commitment, "stored commitment mismatch");
        require(stored.version == 1, "version mismatch");
        require(stored.active, "policy inactive");
    }

    function testNonOwnerCannotRegisterPolicy() public {
        SentinelProtocol.PolicyEnvelope memory policy = _policy(1);

        vm.expectRevert(abi.encodeWithSelector(SentinelPolicyRegistry.UnauthorizedPolicyOwner.selector, address(this)));
        registry.registerPolicy(policy);
    }

    function testUpdateRequiresSequentialVersion() public {
        SentinelProtocol.PolicyEnvelope memory policy = _policy(1);
        vm.prank(OWNER);
        registry.registerPolicy(policy);

        SentinelProtocol.PolicyEnvelope memory invalidUpdate = _policy(3);
        vm.prank(OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(SentinelPolicyRegistry.PolicyVersionNotSequential.selector, uint64(2), uint64(3))
        );
        registry.updatePolicy(invalidUpdate);

        SentinelProtocol.PolicyEnvelope memory validUpdate = _policy(2);
        validUpdate.rulesHash = keccak256("updated-rules");
        vm.prank(OWNER);
        bytes32 updatedCommitment = registry.updatePolicy(validUpdate);

        ISentinelPolicyRegistry.PolicyRecord memory stored = registry.getPolicy(POLICY_ID);
        require(stored.version == 2, "version not updated");
        require(stored.commitment == updatedCommitment, "commitment not updated");
    }

    function testRevokedPolicyIsInactive() public {
        SentinelProtocol.PolicyEnvelope memory policy = _policy(1);
        vm.prank(OWNER);
        bytes32 commitment = registry.registerPolicy(policy);

        vm.prank(OWNER);
        registry.revokePolicy(POLICY_ID);

        bool active = registry.isPolicyActive(POLICY_ID, commitment, ACCOUNT, 1, policy.validAfter);
        require(!active, "revoked policy remains active");
    }

    function _policy(uint64 version) private pure returns (SentinelProtocol.PolicyEnvelope memory policy) {
        policy.protocolVersion = 1;
        policy.schemaVersion = 1;
        policy.policyId = POLICY_ID;
        policy.owner = OWNER;
        policy.account = ACCOUNT;
        policy.policyVersion = version;
        policy.validAfter = 1_900_000_000;
        policy.validUntil = 2_100_000_000;
        policy.chainScopeHash = keccak256("chain-scope");
        policy.rulesHash = keccak256("rules");
        policy.metadataHash = keccak256("metadata");
    }
}
