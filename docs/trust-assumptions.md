# Trust Assumptions

## Trusted

- The attested confidential-compute hardware and firmware satisfy their documented security properties.
- The registered Sentinel code measurement corresponds to reviewed source and build inputs.
- The deterministic policy engine and canonical encoders are correctly implemented.
- The accepted onchain verifier and registry enforce the documented protocol.

## Minimized or untrusted

- AI agents and language models.
- MCP servers and other tools.
- Frontends and relayers.
- Public extension proxies.
- TEE host operators.
- Individual RPC providers.
- Transaction submitters.

## Residual trust

Confidential computing reduces host trust but does not eliminate hardware, firmware, supply-chain, side-channel, governance, or implementation risk. Production deployment requires code reproducibility, attestation verification, key rotation, independent review, and incident response.
