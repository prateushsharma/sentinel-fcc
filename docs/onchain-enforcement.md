# Onchain Policy and Execution Boundary

## Components

### `SentinelPolicyRegistry`

The registry stores only public commitments and lifecycle metadata:

- immutable policy ID;
- immutable owner and protected account identity;
- current commitment and strictly increasing version;
- validity window;
- active or revoked state.

Private policy rules are never published. Updating a policy requires the current
owner and exactly the next version. Revocation is terminal for that policy ID.

### `SentinelExecutor`

Each executor is a smart-account boundary. A call executes only when all of the
following hold:

1. the intent targets the current chain and executor;
2. the protected account is the executor itself;
3. the intent and decision validity windows are active;
4. the decision binds the exact intent hash and execution fields;
5. the policy commitment/version is currently active;
6. the simulation block is historical, recent, and has the canonical block hash;
7. the verifier accepts the EIP-712 decision digest;
8. the request ID and decision hash have not been consumed;
9. the agent supplies its exact next nonce.

Replay state is written before the target call. If the target reverts, the whole
transaction—including replay-state writes—reverts atomically.

## Domain separation

The executor computes:

```text
keccak256(
  0x1901 ||
  EIP712Domain(
    name = "SentinelFCC",
    version = "1",
    chainId = block.chainid,
    verifyingContract = executor
  ) ||
  SentinelFirewallDecision struct hash
)
```

A proof issued for one chain or executor cannot be replayed against another.

## Verifier abstraction

`ISentinelDecisionVerifier` allows the executor to remain independent of the
proof mechanism. `SentinelECDSADecisionVerifier` is an immutable, low-s,
65-byte secp256k1 verifier suitable for a TEE-controlled signing key.

A future FCC-native verifier can validate ActionResult attestations directly by
implementing the same interface.

## Current execution model

The executor calls targets from its own address and balance. Therefore, a
registered policy's `account` must equal the executor address. Safe modules and
other smart-account adapters will be separate integrations.
