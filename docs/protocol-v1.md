# Sentinel Protocol v1

## Status

Protocol v1 defines canonical, cross-language hashes for policy envelopes,
transaction intents, evaluation requests, and firewall decisions. These hashes
are foundational commitments. They are not final signatures and are not yet
authorizations accepted by an executor.

## Encoding rules

Every struct hash is:

```text
keccak256(abi.encode(TYPEHASH, field_1, field_2, ...))
```

Rules:

- Integer widths in the type string are normative.
- ABI encoding pads every fixed value to a 32-byte word.
- Addresses are encoded as Solidity `address`.
- `uint256` values must be non-negative and at most 256 bits.
- Dynamic transaction calldata is represented by `keccak256(data)`.
- Field order is normative.
- A schema change requires a new version and new type string.
- JSON is an API representation only; it is never the signature preimage.

## Canonical type strings

```text
SentinelPolicy(uint16 protocolVersion,uint16 schemaVersion,bytes32 policyId,address owner,address account,uint64 policyVersion,uint64 validAfter,uint64 validUntil,bytes32 chainScopeHash,bytes32 rulesHash,bytes32 metadataHash)
```

```text
SentinelTransactionIntent(uint16 protocolVersion,uint256 chainId,address executor,address account,address agent,address target,uint256 value,bytes32 calldataHash,uint64 nonce,uint64 validAfter,uint64 validUntil)
```

```text
SentinelEvaluationRequest(uint16 protocolVersion,bytes32 requestId,bytes32 policyId,bytes32 policyCommitment,uint64 policyVersion,bytes32 intentHash,uint64 requestedAt)
```

```text
SentinelFirewallDecision(uint16 protocolVersion,uint16 decisionVersion,bytes32 requestId,bytes32 intentHash,bytes32 policyId,bytes32 policyCommitment,uint64 policyVersion,uint256 chainId,address executor,address account,address agent,uint64 nonce,uint64 validAfter,uint64 validUntil,uint64 simulationBlockNumber,bytes32 simulationBlockHash,bytes32 simulationHash,bool approved,uint8 riskScore,uint256 riskFlags)
```

## Security properties established

- Changing one calldata byte changes the intent hash.
- Chain, executor, protected account, agent, target, value, nonce, and validity
  window are bound to the intent.
- The request binds one request ID, policy version, policy commitment, and
  exact intent hash.
- The decision binds the simulation state and normalized simulation result.
- Risk flags have stable bit positions across Go and Solidity.
- Golden vectors prove Go and Solidity produce identical hashes.

## Not yet implemented

Protocol v1 does not yet include:

- EIP-712 domain separation and signature recovery;
- onchain nonce consumption;
- policy registration or revocation contracts;
- encrypted private-policy transport;
- TEE ActionResult verification;
- transaction execution.

Those are separate layers built on these canonical commitments.
