package protocol

const (
	// CurrentProtocolVersion identifies the canonical Sentinel message family.
	CurrentProtocolVersion uint16 = 1

	// CurrentPolicySchemaVersion identifies the private policy-envelope schema.
	CurrentPolicySchemaVersion uint16 = 1

	// CurrentDecisionVersion identifies the firewall-decision schema.
	CurrentDecisionVersion uint16 = 1

	// MaximumRiskScore is the inclusive upper bound for normalized risk scores.
	MaximumRiskScore uint8 = 100
)
