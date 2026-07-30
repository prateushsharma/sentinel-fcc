# Confidential Policy Engine

## Data boundary

The public chain stores only:

- policy identity and version;
- owner and protected account;
- validity window;
- chain-scope commitment;
- private-rules commitment;
- metadata commitment.

The private policy itself is encrypted to a specifically selected TEE. The
`InstructionSender` sends only ciphertext. Inside the extension, the ciphertext
is passed to tee-node's loopback `/decrypt` endpoint; plaintext is decoded and
evaluated only after decryption.

## Canonical private policy

Policy v1 includes:

- allowed chain IDs;
- authorized agent addresses;
- global native-value limit;
- maximum acceptable risk score;
- maximum simulation-block age;
- simulation-success and provider-agreement requirements;
- exact target allowlist;
- optional target code hashes;
- selector allowlists;
- per-target native-value limits;
- ERC-20 transfer and approval limits;
- unlimited-approval policy;
- recipient/spender allowlists.

Sets are sorted, duplicates are rejected, uint256 values use canonical decimal
strings, and selectors use lowercase `0x` plus eight hex digits. The normalized
JSON field order is fixed by the Go schema.

Two hashes are calculated:

```text
rulesHash      = keccak256(canonical private-rules JSON)
chainScopeHash = keccak256(canonical allowed-chain JSON)
```

Both must match the public `PolicyEnvelope`. A mutated plaintext policy cannot
reuse an old onchain commitment.

## Deterministic evaluation order

The engine evaluates inputs in a fixed order:

1. validity windows;
2. chain scope;
3. agent authorization;
4. global native-value limit;
5. target lookup;
6. target value and selector rules;
7. strict ERC-20 decoding and limits;
8. target code-hash binding;
9. simulation completeness, age, success, and provider agreement.

Risk flags and reasons are inserted in that same order. Repeating an identical
request produces the same decision and decision hash.

## Current trust boundary

Patch 006 consumes a normalized simulation snapshot. The engine validates its
binding to the exact intent, but it does not yet fetch RPC state itself. The next
simulation-provider layer will obtain traces from independent providers,
normalize effects, and set `providerAgreement`.

The extension returns the canonical firewall decision in `ActionResult.Data`.
FCC signs the result envelope. Bridging that attested result into the executor's
decision-verifier interface is a separate integration layer.
