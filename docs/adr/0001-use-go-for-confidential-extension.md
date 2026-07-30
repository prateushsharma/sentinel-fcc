# ADR-0001: Use Go for the confidential extension

- Status: Accepted
- Date: 2026-07-30

## Context

The Flare FCC scaffold supports Go, Python, and TypeScript. Sentinel's extension will contain security-sensitive parsers, canonical encoders, simulation adapters, policy evaluation, and concurrency-controlled state.

## Decision

Use Go for the confidential extension and Flare deployment tooling integration.

## Reasons

- The upstream Go image is the smallest and strongest reproducibility path.
- Static typing and explicit error handling suit security-sensitive protocol code.
- A static binary and minimal runtime reduce image size and attack surface.
- The upstream scaffold and deployment tooling already use Go extensively.

## Consequences

The web client and SDK may use TypeScript, but normative protocol vectors must prove cross-language encoding compatibility.
