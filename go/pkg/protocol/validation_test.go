package protocol_test

import (
	"math/big"
	"testing"

	"extension-scaffold/internal/protocolvectors"
	"extension-scaffold/pkg/protocol"
)

func TestGoldenFixtureValidates(t *testing.T) {
	fixture, err := protocolvectors.BuildFixture()
	if err != nil {
		t.Fatal(err)
	}

	if err := protocol.ValidatePolicyEnvelope(fixture.Policy); err != nil {
		t.Fatalf("policy validation failed: %v", err)
	}
	if err := protocol.ValidateTransactionIntent(fixture.Intent); err != nil {
		t.Fatalf("intent validation failed: %v", err)
	}
	if err := protocol.ValidateEvaluationRequest(fixture.Request); err != nil {
		t.Fatalf("request validation failed: %v", err)
	}
	if err := protocol.ValidateFirewallDecision(fixture.Decision); err != nil {
		t.Fatalf("decision validation failed: %v", err)
	}
}

func TestUint256OverflowRejected(t *testing.T) {
	fixture, err := protocolvectors.BuildFixture()
	if err != nil {
		t.Fatal(err)
	}

	fixture.Intent.Value = new(big.Int).Lsh(big.NewInt(1), 256)
	if err := protocol.ValidateTransactionIntent(fixture.Intent); err == nil {
		t.Fatal("expected uint256 overflow to be rejected")
	}
}

func TestRiskFlagMask(t *testing.T) {
	mask, err := protocol.CombineRiskFlags(
		protocol.RiskUnknownTarget,
		protocol.RiskUnlimitedApproval,
	)
	if err != nil {
		t.Fatal(err)
	}

	if !protocol.HasRiskFlag(mask, protocol.RiskUnknownTarget) {
		t.Fatal("unknown-target flag missing")
	}
	if !protocol.HasRiskFlag(mask, protocol.RiskUnlimitedApproval) {
		t.Fatal("unlimited-approval flag missing")
	}
	if protocol.HasRiskFlag(mask, protocol.RiskSimulationFailed) {
		t.Fatal("unexpected simulation-failed flag")
	}
}
