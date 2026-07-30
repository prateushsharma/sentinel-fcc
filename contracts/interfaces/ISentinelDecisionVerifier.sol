// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @title ISentinelDecisionVerifier
/// @notice Verifies an already domain-separated Sentinel decision digest.
interface ISentinelDecisionVerifier {
    /// @param decisionDigest EIP-712 digest scoped to one executor deployment.
    /// @param proof Verifier-specific proof, signature, or attestation bytes.
    function verifyDecision(bytes32 decisionDigest, bytes calldata proof) external view returns (bool);
}
