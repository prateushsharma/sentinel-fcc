// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {SentinelECDSADecisionVerifier} from "../contracts/SentinelECDSADecisionVerifier.sol";

interface VmECDSA {
    function addr(uint256 privateKey) external returns (address);
    function sign(uint256 privateKey, bytes32 digest) external returns (uint8 v, bytes32 r, bytes32 s);
}

contract SentinelECDSADecisionVerifierTest {
    VmECDSA private constant vm = VmECDSA(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 private constant SIGNER_KEY = 0xA11CE;

    function testValidSignatureAccepted() public {
        address signer = vm.addr(SIGNER_KEY);
        SentinelECDSADecisionVerifier verifier = new SentinelECDSADecisionVerifier(signer);
        bytes32 digest = keccak256("sentinel-decision-digest");

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, digest);
        bytes memory proof = abi.encodePacked(r, s, v);

        require(verifier.verifyDecision(digest, proof), "valid signature rejected");
    }

    function testWrongDigestAndMalformedProofRejected() public {
        address signer = vm.addr(SIGNER_KEY);
        SentinelECDSADecisionVerifier verifier = new SentinelECDSADecisionVerifier(signer);
        bytes32 digest = keccak256("sentinel-decision-digest");

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, digest);
        bytes memory proof = abi.encodePacked(r, s, v);

        require(!verifier.verifyDecision(keccak256("wrong"), proof), "wrong digest accepted");
        require(!verifier.verifyDecision(digest, hex"1234"), "malformed proof accepted");
    }
}
