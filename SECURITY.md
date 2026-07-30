# Security Policy

SentinelFCC is experimental security infrastructure and must not be used to custody production funds at this stage.

## Reporting a vulnerability

Do not open a public issue containing exploit details, private keys, confidential policies, or vulnerable deployment information.

Until a dedicated private disclosure channel is published, contact the repository owner through their verified GitHub profile and request a private reporting channel. Include only a minimal non-sensitive summary in the initial contact.

## Supported versions

Only the latest commit on `main` is considered for security fixes. Development branches may contain incomplete or unsafe functionality.

## Secrets

Never commit wallet keys, TEE keys, RPC credentials, database credentials, `.env` files, policy plaintext, decrypted requests, or production addresses with sensitive operational meaning.
