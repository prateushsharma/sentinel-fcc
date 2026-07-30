# Quorum Transaction Simulation

## Purpose

Sentinel no longer accepts a simulation snapshot supplied by the agent or
client. The TEE extension derives the snapshot from independent JSON-RPC
providers after decrypting and validating the request.

## Provider configuration

The extension reads:

```text
SENTINEL_RPC_URLS=https://rpc-a.example,https://rpc-b.example,https://rpc-c.example
SENTINEL_RPC_QUORUM=2
SENTINEL_RPC_TIMEOUT=12s
```

`SENTINEL_RPC_QUORUM` defaults to a strict majority. One-provider operation is
supported for local development, but production deployments should use
independently operated providers and quorum greater than one.

## Canonical block anchoring

For each evaluation, Sentinel:

1. requests `latest` from every provider;
2. takes the lowest successfully observed latest block;
3. selects the preceding block so simulation is historical;
4. fetches that exact block from every responsive provider;
5. requires quorum agreement on its hash;
6. rechecks the block hash after each simulation to reject mid-flight reorgs.

If a canonical block cannot be established, evaluation fails without issuing an
executable decision.

## RPC simulation

Every provider receives the same downstream call:

```text
from  = SentinelExecutor
to    = intent target
value = intent value
data  = exact intent calldata
block = quorum-anchored historical block
```

Sentinel calls:

- `debug_traceCall` with the call tracer and logs enabled;
- `eth_getCode` for the target at the same block;
- `eth_getBlockByNumber` again after tracing.

Providers that do not support the required trace method do not contribute to
quorum.

## Normalized effects

Client-specific gas fields and error text are excluded. Sentinel commits to:

- top-level success and return-data hash;
- every call frame in deterministic depth-first trace order;
- call type, addresses, value, selector, input hash, output hash, and success;
- every native-value transfer;
- canonical ERC-20 `Transfer` events;
- canonical ERC-20 `Approval` events;
- every raw log through emitter, topics, and data hash;
- target bytecode hash.

The canonical JSON is hashed with Keccak-256 to create `effectsHash`.

## Agreement and disagreement

A provider result is grouped by:

```text
effectsHash
success
targetCodeHash
```

When at least quorum providers match, `providerAgreement=true` and the agreed
snapshot enters the private policy engine.

When enough providers complete simulation but no group reaches quorum,
Sentinel creates a deterministic hash over the sorted conflicting result
digests and returns:

```text
providerAgreement=false
success=false
effectsHash=<disagreement evidence hash>
```

The policy engine then produces a `PROVIDER_DISAGREEMENT` denial. No provider's
arbitrary effects are selected as authoritative.

## Fail-closed cases

Evaluation fails without an executable decision when:

- too few providers return a latest block;
- providers cannot agree on one historical block hash;
- too few providers complete trace and code queries;
- a provider reorgs during simulation;
- trace size or depth exceeds defensive limits.

The client request schema intentionally contains no simulation field. Unknown
fields are rejected, so an agent cannot inject a trusted-looking snapshot.
