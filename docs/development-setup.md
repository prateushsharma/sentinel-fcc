# Development Workstation Setup

SentinelFCC currently standardizes local extension development on:

- Ubuntu or another compatible Linux environment;
- Go 1.25.12;
- Docker with an accessible daemon;
- Foundry (`forge` and `cast`);
- `jq`;
- ShellCheck;
- Git.

The project intentionally uses the latest patch release in the Go 1.25 line rather than upgrading to a new language minor without a reviewed compatibility change.

## Automated setup

From the repository root:

```bash
./scripts/patches/003-prepare-workstation.sh
```

The script obtains release metadata from the official Go download API, verifies the archive SHA-256 value, safely replaces `/usr/local/go`, configures the local ignored `.env`, runs project verification, and commits the tracked setup changes.

## Verification

```bash
./scripts/sentinel/check-dev-env.sh --strict
./scripts/sentinel/verify.sh
```

The full FCC local end-to-end lifecycle is separate:

```bash
./scripts/full-setup.sh --test
```

Do not commit `.env`, private keys, RPC credentials, TEE credentials, or other machine-specific values.
