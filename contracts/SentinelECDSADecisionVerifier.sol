// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ISentinelDecisionVerifier} from "./interfaces/ISentinelDecisionVerifier.sol";

/// @title SentinelECDSADecisionVerifier
/// @notice Strict immutable-signer verifier for domain-separated decision digests.
/// @dev The signer may be a TEE-controlled secp256k1 key. FCC-native attestation
///      verification can implement ISentinelDecisionVerifier without changing the executor.
contract SentinelECDSADecisionVerifier is ISentinelDecisionVerifier {
    // secp256k1n / 2, enforcing EIP-2 low-s signatures.
    uint256 private constant _MAX_VALID_S = 0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0;

    address public immutable signer;

    error InvalidSigner();

    constructor(address signer_) {
        if (signer_ == address(0)) {
            revert InvalidSigner();
        }
        signer = signer_;
    }

    function verifyDecision(bytes32 decisionDigest, bytes calldata proof) external view returns (bool) {
        if (proof.length != 65) {
            return false;
        }

        bytes32 r;
        bytes32 s;
        uint8 v;

        assembly ("memory-safe") {
            r := calldataload(proof.offset)
            s := calldataload(add(proof.offset, 32))
            v := byte(0, calldataload(add(proof.offset, 64)))
        }

        if (uint256(s) > _MAX_VALID_S || (v != 27 && v != 28)) {
            return false;
        }

        address recovered = ecrecover(decisionDigest, v, r, s);
        return recovered != address(0) && recovered == signer;
    }
}
