# Contributing

## Branches

- `main`: reviewed, releasable repository state.
- `develop`: integration branch.
- `feat/*`, `fix/*`, `docs/*`, `chore/*`, `security/*`: short-lived work branches.

## Commit style

Use Conventional Commits, for example:

```text
feat(protocol): add canonical intent hashing
fix(executor): consume decision nonce before external call
test(policy): cover nested unlimited approvals
docs(threat-model): define RPC disagreement handling
```

## Required checks

```bash
./scripts/sentinel/check-dev-env.sh
./scripts/sentinel/verify.sh
```

Changes affecting signed data must include updated golden vectors and cross-language compatibility tests. Security-relevant changes must update the threat model or explain why no documentation change is required.
