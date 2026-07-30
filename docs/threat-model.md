# Threat Model

## Protected assets

- Funds and permissions controlled by protected accounts.
- Private account policies, allowlists, limits, and strategy metadata.
- Unpublished transaction intents and rejected malicious payloads.
- TEE signing and decryption authority.
- Policy and agent authorization state.

## Adversaries

- Compromised or prompt-injected AI agent.
- Malicious MCP server, API, website, document, or peer agent.
- Malicious frontend, relayer, public proxy, or network observer.
- RPC provider returning stale or manipulated simulation data.
- TEE host operator attempting to inspect or alter processing.
- Contract caller attempting substitution, replay, or cross-chain reuse.
- Compromised administrator or governance signer.

## Required invariants

1. Only an authenticated, authorized agent can request evaluation for an account.
2. The evaluated intent and executed intent are byte-for-byte equivalent under the canonical encoding.
3. Every decision is scoped to the protocol version, chain, executor, account, agent, policy version, nonce, and validity window.
4. Revoked or superseded policies cannot authorize new execution.
5. Every authorization is single-use.
6. Unknown, malformed, stale, inconsistent, or failed analysis denies execution.
7. Sensitive values are excluded from application logs, metrics, traces, and error responses.
8. Administrative changes are explicit, auditable, and recoverable through a documented process.

## Out of scope for the first audited release

- Protection against all hardware side channels.
- Privacy of calldata after an approved public-chain transaction executes.
- Correctness of external protocols called by an approved transaction.
- Recovery of funds already transferred before Sentinel protection was enabled.
