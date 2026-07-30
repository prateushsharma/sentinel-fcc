# SentinelFCC

**Confidential transaction firewall for autonomous onchain agents using Flare Confidential Compute.**

SentinelFCC treats the AI agent, its tools, retrieved content, relayers, frontends, and TEE host operator as potentially compromised. A transaction executes only when a registered confidential-compute extension has evaluated the exact intent against the account owner's private policy and returned a valid, unexpired, replay-protected authorization.

## Core flow

```text
Agent proposes an intent
        ↓
Client authenticates and encrypts the evaluation request
        ↓
Sentinel extension decodes, simulates, and evaluates it inside a TEE
        ↓
TEE returns an attested allow/deny decision bound to the exact intent
        ↓
Sentinel onchain guard verifies the decision
        ↓
Approved intent executes; rejected or unverifiable intent fails closed
```

## Security invariants

1. No protected account transaction executes without a valid Sentinel authorization.
2. An authorization is valid for one exact transaction, account, chain, policy version, nonce, and time window.
3. A decision cannot be replayed or reused after policy revocation.
4. Failed, stale, unsupported, or ambiguous analysis results in denial.
5. Plaintext policy data and rejected transaction details must not be exposed through logs, proxies, or onchain storage.

## Repository status

The repository is under active development. The current base is Flare Foundation's FCC extension scaffold, retained as the `flare-upstream` Git remote. Production deployment is not recommended until the protocol, contracts, extension, infrastructure, and operational controls have completed independent security review.

## Development

The extension implementation language is Go.

```bash
cp .env.example .env
# Ensure LANGUAGE=go
./scripts/sentinel/check-dev-env.sh
./scripts/sentinel/verify.sh
```

The full local onchain lifecycle additionally requires Flare's local FCC/e2e infrastructure:

```bash
./scripts/full-setup.sh --test
```

## Documentation

- [Architecture](docs/architecture.md)
- [Threat model](docs/threat-model.md)
- [Protocol](docs/protocol.md)
- [Policy schema](docs/policy-schema.md)
- [Decision format](docs/decision-format.md)
- [Trust assumptions](docs/trust-assumptions.md)
- [Failure modes](docs/failure-modes.md)
- [Deployment security](docs/deployment-security.md)
- [Upstream integration](docs/upstream.md)
- [Contributing](CONTRIBUTING.md)
- [Security policy](SECURITY.md)

## License

No project license has been selected yet. Flare scaffold components retain their original notices and licensing terms.
