# Architecture

## Components

### Sentinel client SDK

The client SDK canonicalizes transaction intents, authenticates requests, encrypts confidential inputs for the selected TEE deployment, submits evaluations, and verifies returned metadata before forwarding an authorization to the onchain guard.

### Confidential extension

The extension performs:

1. request authentication and replay checks;
2. policy retrieval and commitment validation;
3. calldata and nested-call decoding;
4. transaction simulation and effect normalization;
5. deterministic policy evaluation;
6. risk-flag and decision generation;
7. attested result construction.

The extension must not use an LLM to decide whether a transaction is approved. An LLM may produce a non-authoritative explanation after the deterministic decision has been created.

### Onchain policy registry

The registry stores policy commitments, policy versions, authorized agents, revocation state, and accepted verifier/code versions. It does not store plaintext policies.

### Onchain verifier and executor

The verifier authenticates the FCC result and decodes the versioned decision. The executor checks exact-intent binding, account and chain scope, policy state, nonce consumption, time bounds, and emergency controls before executing the call.

### Simulation providers

Simulation is accessed through a provider-neutral interface. The production target is a quorum of independent providers. Provider disagreement, stale state, unsupported traces, or incomplete effects fail closed.

## Data classification

| Data | Classification | Intended location |
|---|---|---|
| Plaintext policy | Confidential | TEE only |
| Proposed rejected intent | Confidential | Client and TEE only |
| Approved transaction calldata | Public after execution | Blockchain |
| Policy commitment | Public | Registry |
| Decision metadata | Public/minimized | Verifier and executor |
| Detailed simulation trace | Confidential | TEE only |
| Coarse risk flags | Configurable/public | Decision |

## Upgrade model

Protocol messages are explicitly versioned. Policy schemas, decision schemas, decoders, and accepted TEE code versions evolve through controlled migration. The executor must never reinterpret an old signed payload under a new schema.
