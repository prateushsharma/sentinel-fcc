// Package protocol defines SentinelFCC's versioned canonical messages.
//
// Hashes produced by this package are ABI-compatible Solidity struct hashes.
// They are not final EIP-712 signing digests; the onchain verifier will later
// combine them with a chain- and contract-scoped EIP-712 domain.
package protocol
