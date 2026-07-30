# Policy Schema

Policies are private, owner-authenticated, versioned objects. Their public representation is a commitment and lifecycle metadata.

## Planned rule groups

- chain and account scope;
- authorized agents and request limits;
- target address and runtime bytecode rules;
- function-selector and operation rules;
- native, fungible-token, and NFT transfer limits;
- approval and permit restrictions;
- recipient and spender controls;
- protocol-specific constraints;
- rolling spend budgets;
- simulation freshness and provider quorum;
- default action and emergency restrictions.

## Compatibility rules

- `schemaVersion` selects the parser.
- `policyVersion` is monotonic per protected account.
- Unknown required fields cause rejection.
- Older versions remain valid only during an explicit migration window.
- A policy update invalidates authorizations tied to prior versions unless the registry explicitly permits a grace period.
