# Decision Format

A firewall decision must bind at least:

- protocol and decision schema versions;
- request ID and canonical intent hash;
- policy commitment and policy version;
- chain ID, executor, protected account, and authorized agent;
- target, value, and calldata hash;
- nonce and validity window;
- simulation block number/hash and normalized simulation commitment;
- approval boolean, risk score, and machine-readable risk flags.

## Replay resistance

The executor consumes the nonce or decision ID before external execution. A reverted external call must not accidentally make the authorization reusable unless the protocol explicitly defines safe retry semantics.

## Domain separation

The signed preimage must include an unambiguous Sentinel domain, chain ID, and verifying contract. No generic message signature is accepted.
