// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @title ISentinelPolicyRegistry
/// @notice Public commitment registry for private Sentinel policy versions.
interface ISentinelPolicyRegistry {
    struct PolicyRecord {
        address owner;
        address account;
        bytes32 commitment;
        uint64 version;
        uint64 validAfter;
        uint64 validUntil;
        bool active;
    }

    function getPolicy(bytes32 policyId) external view returns (PolicyRecord memory);

    function isPolicyActive(bytes32 policyId, bytes32 commitment, address account, uint64 version, uint256 timestamp)
        external
        view
        returns (bool);
}
