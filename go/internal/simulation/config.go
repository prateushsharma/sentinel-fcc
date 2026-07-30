package simulation

import (
	"fmt"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
)

const (
	envRPCURLs = "SENTINEL_RPC_URLS"
	envQuorum  = "SENTINEL_RPC_QUORUM"
	envTimeout = "SENTINEL_RPC_TIMEOUT"

	defaultTimeout = 12 * time.Second
)

// NewFromEnvironment constructs a simulator from comma-separated RPC URLs.
//
// Example:
// SENTINEL_RPC_URLS=https://rpc-a.example,https://rpc-b.example
// SENTINEL_RPC_QUORUM=2
// SENTINEL_RPC_TIMEOUT=12s
func NewFromEnvironment() (*QuorumSimulator, error) {
	rawURLs := strings.TrimSpace(os.Getenv(envRPCURLs))
	if rawURLs == "" {
		return nil, fmt.Errorf("%s is not configured", envRPCURLs)
	}

	parts := strings.Split(rawURLs, ",")
	configs := make([]ProviderConfig, 0, len(parts))
	seen := make(map[string]struct{}, len(parts))
	for index, part := range parts {
		endpoint := strings.TrimSpace(part)
		if endpoint == "" {
			return nil, fmt.Errorf("%s contains an empty URL at position %d", envRPCURLs, index)
		}

		parsed, err := url.Parse(endpoint)
		if err != nil {
			return nil, fmt.Errorf("parse RPC URL %d: %w", index, err)
		}
		if parsed.Scheme != "http" && parsed.Scheme != "https" {
			return nil, fmt.Errorf("RPC URL %d must use http or https", index)
		}
		if parsed.Host == "" || parsed.Fragment != "" {
			return nil, fmt.Errorf("RPC URL %d is malformed", index)
		}
		if _, exists := seen[endpoint]; exists {
			return nil, fmt.Errorf("duplicate RPC URL at position %d", index)
		}
		seen[endpoint] = struct{}{}
		configs = append(configs, ProviderConfig{URL: endpoint})
	}

	quorum := len(configs)/2 + 1
	if rawQuorum := strings.TrimSpace(os.Getenv(envQuorum)); rawQuorum != "" {
		parsed, err := strconv.Atoi(rawQuorum)
		if err != nil {
			return nil, fmt.Errorf("parse %s: %w", envQuorum, err)
		}
		quorum = parsed
	}

	timeout := defaultTimeout
	if rawTimeout := strings.TrimSpace(os.Getenv(envTimeout)); rawTimeout != "" {
		parsed, err := time.ParseDuration(rawTimeout)
		if err != nil {
			return nil, fmt.Errorf("parse %s: %w", envTimeout, err)
		}
		timeout = parsed
	}

	return NewQuorumSimulator(configs, quorum, timeout)
}

// NewQuorumSimulator validates configuration and creates a simulator.
func NewQuorumSimulator(
	configs []ProviderConfig,
	quorum int,
	timeout time.Duration,
) (*QuorumSimulator, error) {
	if len(configs) == 0 {
		return nil, fmt.Errorf("at least one RPC provider is required")
	}
	if quorum <= 0 || quorum > len(configs) {
		return nil, fmt.Errorf("quorum %d is invalid for %d providers", quorum, len(configs))
	}
	if timeout <= 0 {
		return nil, fmt.Errorf("RPC timeout must be positive")
	}

	providers := make([]*rpcProvider, len(configs))
	for index, config := range configs {
		provider, err := newRPCProvider(index, config.URL, timeout)
		if err != nil {
			return nil, fmt.Errorf("configure provider %d: %w", index, err)
		}
		providers[index] = provider
	}

	return &QuorumSimulator{
		providers: providers,
		quorum:    quorum,
		timeout:   timeout,
	}, nil
}
