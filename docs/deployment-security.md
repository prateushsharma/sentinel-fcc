# Deployment Security

Production deployment requires:

- reproducible, pinned extension images;
- minimal runtime images without interactive tooling;
- verified TEE measurements and accepted code-version governance;
- separate development, staging, and production keys;
- threshold-controlled administrative actions;
- explicit key-generation, backup, rotation, and revocation procedures;
- multiple TEE deployments and health monitoring;
- multiple independent simulation providers;
- rate limiting, authenticated requests, and idempotency;
- secret-free structured logs and privacy-reviewed telemetry;
- dependency, container, contract, and infrastructure scanning;
- Foundry unit, fuzz, invariant, fork, and integration tests;
- independent smart-contract and confidential-extension review;
- documented incident response and recovery drills.

The first public deployment remains a testnet system until Flare FCC and SentinelFCC are both suitable for production use.
