package protocol

import (
	"fmt"
	"math/big"
)

// RiskFlag identifies one bit in FirewallDecision.RiskFlags.
type RiskFlag uint8

const (
	RiskUnknownTarget RiskFlag = iota
	RiskSelectorNotAllowed
	RiskUnlimitedApproval
	RiskApprovalTooLarge
	RiskTransferTooLarge
	RiskRecipientNotAllowed
	RiskSimulationFailed
	RiskSimulationStale
	RiskProviderDisagreement
	RiskMalformedCalldata
	RiskUnsupportedOperation
	RiskPolicyMissing
	RiskPolicyRevoked
	RiskAgentUnauthorized
	RiskRequestExpired
	RiskNonceReused
	RiskCodeHashMismatch
	RiskNestedCallOpaque

	riskFlagCount
)

var riskFlagNames = map[RiskFlag]string{
	RiskUnknownTarget:        "UNKNOWN_TARGET",
	RiskSelectorNotAllowed:   "SELECTOR_NOT_ALLOWED",
	RiskUnlimitedApproval:    "UNLIMITED_APPROVAL",
	RiskApprovalTooLarge:     "APPROVAL_TOO_LARGE",
	RiskTransferTooLarge:     "TRANSFER_TOO_LARGE",
	RiskRecipientNotAllowed:  "RECIPIENT_NOT_ALLOWED",
	RiskSimulationFailed:     "SIMULATION_FAILED",
	RiskSimulationStale:      "SIMULATION_STALE",
	RiskProviderDisagreement: "PROVIDER_DISAGREEMENT",
	RiskMalformedCalldata:    "MALFORMED_CALLDATA",
	RiskUnsupportedOperation: "UNSUPPORTED_OPERATION",
	RiskPolicyMissing:        "POLICY_MISSING",
	RiskPolicyRevoked:        "POLICY_REVOKED",
	RiskAgentUnauthorized:    "AGENT_UNAUTHORIZED",
	RiskRequestExpired:       "REQUEST_EXPIRED",
	RiskNonceReused:          "NONCE_REUSED",
	RiskCodeHashMismatch:     "CODE_HASH_MISMATCH",
	RiskNestedCallOpaque:     "NESTED_CALL_OPAQUE",
}

// String returns the stable machine-readable name of the flag.
func (f RiskFlag) String() string {
	if name, ok := riskFlagNames[f]; ok {
		return name
	}
	return fmt.Sprintf("UNKNOWN_RISK_FLAG_%d", uint8(f))
}

// Mask returns a fresh uint256-compatible bit mask for the flag.
func (f RiskFlag) Mask() (*big.Int, error) {
	if f >= riskFlagCount {
		return nil, fmt.Errorf("risk flag %d is out of range", f)
	}
	return new(big.Int).Lsh(big.NewInt(1), uint(f)), nil
}

// CombineRiskFlags combines flags into a fresh uint256-compatible mask.
func CombineRiskFlags(flags ...RiskFlag) (*big.Int, error) {
	mask := new(big.Int)
	for _, flag := range flags {
		bit, err := flag.Mask()
		if err != nil {
			return nil, err
		}
		mask.Or(mask, bit)
	}
	return mask, nil
}

// HasRiskFlag reports whether mask contains flag.
func HasRiskFlag(mask *big.Int, flag RiskFlag) bool {
	if mask == nil || flag >= riskFlagCount {
		return false
	}
	return mask.Bit(int(flag)) == 1
}
