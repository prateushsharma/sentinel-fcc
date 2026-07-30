package policy

import (
	"github.com/ethereum/go-ethereum/common"
)

const (
	// CurrentSchemaVersion is the private policy schema supported by this engine.
	CurrentSchemaVersion uint16 = 1

	// MaximumRiskScore is the inclusive upper bound for policy risk thresholds.
	MaximumRiskScore uint8 = 100
)

// PrivatePolicy contains confidential rules evaluated inside the TEE.
//
// Uint256 values are canonical base-10 strings. This avoids JSON precision loss
// and makes the normalized representation portable across languages.
type PrivatePolicy struct {
	SchemaVersion               uint16           `json:"schemaVersion"`
	PolicyID                    common.Hash      `json:"policyId"`
	Owner                       common.Address   `json:"owner"`
	Account                     common.Address   `json:"account"`
	Version                     uint64           `json:"version"`
	ValidAfter                  uint64           `json:"validAfter"`
	ValidUntil                  uint64           `json:"validUntil"`
	AllowedChainIDs             []string         `json:"allowedChainIds"`
	AuthorizedAgents            []common.Address `json:"authorizedAgents"`
	MaxNativeValue              string           `json:"maxNativeValue"`
	MaxRiskScore                uint8            `json:"maxRiskScore"`
	MaxSimulationBlockAge       uint64           `json:"maxSimulationBlockAge"`
	RequireSuccessfulSimulation bool             `json:"requireSuccessfulSimulation"`
	RequireProviderAgreement    bool             `json:"requireProviderAgreement"`
	Targets                     []TargetRule     `json:"targets"`
}

// TargetRule contains rules for one exact destination contract.
type TargetRule struct {
	Target                 common.Address   `json:"target"`
	CodeHash               common.Hash      `json:"codeHash"`
	AllowAnySelector       bool             `json:"allowAnySelector"`
	Selectors              []string         `json:"selectors"`
	MaxNativeValue         string           `json:"maxNativeValue"`
	MaxERC20Transfer       string           `json:"maxErc20Transfer"`
	MaxERC20Approval       string           `json:"maxErc20Approval"`
	AllowUnlimitedApproval bool             `json:"allowUnlimitedApproval"`
	AllowedRecipients      []common.Address `json:"allowedRecipients"`
}
