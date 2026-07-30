# Protocol

## Message families

The protocol will define independently versioned messages for:

- policy registration and update;
- policy revocation;
- agent authorization and revocation;
- transaction evaluation;
- firewall decision;
- execution receipt.

## Canonical encoding

Every signed or committed object must have one normative encoding shared by Go, Solidity, and TypeScript. Golden vectors must cover valid encodings and mutation cases. JSON is an API representation, not the signature preimage.

## Evaluation lifecycle

1. The owner registers a policy commitment and active policy version.
2. An authorized agent creates a transaction intent.
3. The client creates a request ID and signs the canonical evaluation request.
4. Confidential fields are encrypted to an attested TEE recipient.
5. The extension authenticates the request and verifies policy state.
6. The extension decodes and simulates the exact intent.
7. The deterministic engine creates an allow/deny decision.
8. The TEE returns an attested result bound to the canonical decision.
9. The executor validates the result and consumes the nonce.
10. The exact approved transaction executes atomically or reverts.

## Failure semantics

The default action is deny. No exception, timeout, unsupported decoder, unavailable provider, or malformed response may be converted into approval.
