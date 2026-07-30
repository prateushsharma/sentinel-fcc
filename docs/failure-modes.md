# Failure Modes

| Failure | Required behaviour |
|---|---|
| TEE or proxy unavailable | Deny; never bypass |
| Request signature invalid | Deny and emit minimal audit metadata |
| Policy missing, stale, or revoked | Deny |
| Unsupported or malformed calldata | Deny |
| Nested call cannot be fully decoded | Deny unless an explicit reviewed rule permits it |
| Simulation reverts | Deny |
| Simulation providers disagree | Deny |
| Simulation block too old | Deny |
| Attestation or result signature invalid | Onchain rejection |
| Decision expired | Onchain rejection |
| Nonce already consumed | Onchain rejection |
| Intent differs from decision | Onchain rejection |
| Accepted code version revoked | Onchain rejection |
| Administrative compromise suspected | Pause protected execution and begin rotation procedure |

Error responses must not include plaintext policy values, decrypted calldata, secrets, provider credentials, or detailed confidential traces.
