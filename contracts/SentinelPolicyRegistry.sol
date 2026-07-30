// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ISentinelPolicyRegistry} from "./interfaces/ISentinelPolicyRegistry.sol";
import {SentinelProtocol} from "./libraries/SentinelProtocol.sol";

/// @title SentinelPolicyRegistry
/// @notice Stores public commitments and lifecycle state for private policies.
/// @dev Policy rule contents remain offchain/confidential; only commitments live here.
contract SentinelPolicyRegistry is ISentinelPolicyRegistry {
    error InvalidPolicyId();
    error InvalidPolicyOwner();
    error InvalidPolicyAccount();
    error InvalidPolicyVersion();
    error InvalidValidityWindow();
    error UnsupportedProtocolVersion(uint16 supplied);
    error UnsupportedPolicySchemaVersion(uint16 supplied);
    error PolicyAlreadyExists(bytes32 policyId);
    error PolicyNotFound(bytes32 policyId);
    error PolicyNotActive(bytes32 policyId);
    error UnauthorizedPolicyOwner(address caller);
    error PolicyIdentityChanged();
    error PolicyVersionNotSequential(uint64 expected, uint64 supplied);
    error PolicyVersionExhausted();

    event PolicyRegistered(
        bytes32 indexed policyId,
        address indexed owner,
        address indexed account,
        uint64 version,
        bytes32 commitment,
        uint64 validAfter,
        uint64 validUntil
    );

    event PolicyUpdated(
        bytes32 indexed policyId,
        uint64 previousVersion,
        uint64 newVersion,
        bytes32 previousCommitment,
        bytes32 newCommitment,
        uint64 validAfter,
        uint64 validUntil
    );

    event PolicyRevoked(bytes32 indexed policyId, uint64 indexed version, address indexed owner);

    mapping(bytes32 policyId => PolicyRecord record) private _policies;

    function registerPolicy(SentinelProtocol.PolicyEnvelope calldata policy) external returns (bytes32 commitment) {
        _validatePolicyEnvelope(policy);

        if (policy.owner != msg.sender) {
            revert UnauthorizedPolicyOwner(msg.sender);
        }
        if (_policies[policy.policyId].owner != address(0)) {
            revert PolicyAlreadyExists(policy.policyId);
        }

        commitment = SentinelProtocol.hashPolicyEnvelope(policy);
        _policies[policy.policyId] = PolicyRecord({
            owner: policy.owner,
            account: policy.account,
            commitment: commitment,
            version: policy.policyVersion,
            validAfter: policy.validAfter,
            validUntil: policy.validUntil,
            active: true
        });

        emit PolicyRegistered(
            policy.policyId,
            policy.owner,
            policy.account,
            policy.policyVersion,
            commitment,
            policy.validAfter,
            policy.validUntil
        );
    }

    function updatePolicy(SentinelProtocol.PolicyEnvelope calldata policy) external returns (bytes32 commitment) {
        PolicyRecord storage existing = _policies[policy.policyId];

        if (existing.owner == address(0)) {
            revert PolicyNotFound(policy.policyId);
        }
        if (!existing.active) {
            revert PolicyNotActive(policy.policyId);
        }
        if (msg.sender != existing.owner) {
            revert UnauthorizedPolicyOwner(msg.sender);
        }

        _validatePolicyEnvelope(policy);

        if (policy.owner != existing.owner || policy.account != existing.account) {
            revert PolicyIdentityChanged();
        }
        if (existing.version == type(uint64).max) {
            revert PolicyVersionExhausted();
        }

        uint64 expectedVersion = existing.version + 1;
        if (policy.policyVersion != expectedVersion) {
            revert PolicyVersionNotSequential(expectedVersion, policy.policyVersion);
        }

        uint64 previousVersion = existing.version;
        bytes32 previousCommitment = existing.commitment;
        commitment = SentinelProtocol.hashPolicyEnvelope(policy);

        existing.commitment = commitment;
        existing.version = policy.policyVersion;
        existing.validAfter = policy.validAfter;
        existing.validUntil = policy.validUntil;

        emit PolicyUpdated(
            policy.policyId,
            previousVersion,
            policy.policyVersion,
            previousCommitment,
            commitment,
            policy.validAfter,
            policy.validUntil
        );
    }

    function revokePolicy(bytes32 policyId) external {
        PolicyRecord storage existing = _policies[policyId];

        if (existing.owner == address(0)) {
            revert PolicyNotFound(policyId);
        }
        if (!existing.active) {
            revert PolicyNotActive(policyId);
        }
        if (msg.sender != existing.owner) {
            revert UnauthorizedPolicyOwner(msg.sender);
        }

        existing.active = false;
        emit PolicyRevoked(policyId, existing.version, existing.owner);
    }

    function getPolicy(bytes32 policyId) external view returns (PolicyRecord memory) {
        return _policies[policyId];
    }

    function isPolicyActive(bytes32 policyId, bytes32 commitment, address account, uint64 version, uint256 timestamp)
        external
        view
        returns (bool)
    {
        PolicyRecord storage policy = _policies[policyId];

        return policy.active && policy.owner != address(0) && policy.commitment == commitment
            && policy.account == account && policy.version == version && timestamp >= policy.validAfter
            && timestamp <= policy.validUntil;
    }

    function _validatePolicyEnvelope(SentinelProtocol.PolicyEnvelope calldata policy) private pure {
        if (policy.protocolVersion != SentinelProtocol.currentProtocolVersion()) {
            revert UnsupportedProtocolVersion(policy.protocolVersion);
        }
        if (policy.schemaVersion != SentinelProtocol.currentPolicySchemaVersion()) {
            revert UnsupportedPolicySchemaVersion(policy.schemaVersion);
        }
        if (policy.policyId == bytes32(0)) {
            revert InvalidPolicyId();
        }
        if (policy.owner == address(0)) {
            revert InvalidPolicyOwner();
        }
        if (policy.account == address(0)) {
            revert InvalidPolicyAccount();
        }
        if (policy.policyVersion == 0) {
            revert InvalidPolicyVersion();
        }
        if (policy.validUntil == 0 || policy.validAfter > policy.validUntil) {
            revert InvalidValidityWindow();
        }
        if (policy.chainScopeHash == bytes32(0) || policy.rulesHash == bytes32(0) || policy.metadataHash == bytes32(0))
        {
            revert InvalidPolicyId();
        }
    }
}
