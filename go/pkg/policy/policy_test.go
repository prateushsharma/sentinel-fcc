package policy_test

import (
	"testing"

	"extension-scaffold/pkg/policy"
	"extension-scaffold/pkg/protocol"

	"github.com/ethereum/go-ethereum/common"
)

func TestPolicyHashesIgnoreInputOrdering(t *testing.T) {
	first := fixturePolicy()
	second := fixturePolicy()

	second.AllowedChainIDs[0], second.AllowedChainIDs[1] =
		second.AllowedChainIDs[1], second.AllowedChainIDs[0]
	second.AuthorizedAgents[0], second.AuthorizedAgents[1] =
		second.AuthorizedAgents[1], second.AuthorizedAgents[0]
	second.Targets[0].Selectors[0], second.Targets[0].Selectors[1] =
		second.Targets[0].Selectors[1], second.Targets[0].Selectors[0]
	second.Targets[0].AllowedRecipients[0], second.Targets[0].AllowedRecipients[1] =
		second.Targets[0].AllowedRecipients[1], second.Targets[0].AllowedRecipients[0]

	firstRules, err := policy.RulesHash(first)
	if err != nil {
		t.Fatal(err)
	}
	secondRules, err := policy.RulesHash(second)
	if err != nil {
		t.Fatal(err)
	}
	if firstRules != secondRules {
		t.Fatal("rules hash changed when unordered sets were reordered")
	}

	firstChains, err := policy.ChainScopeHash(first)
	if err != nil {
		t.Fatal(err)
	}
	secondChains, err := policy.ChainScopeHash(second)
	if err != nil {
		t.Fatal(err)
	}
	if firstChains != secondChains {
		t.Fatal("chain-scope hash changed when chains were reordered")
	}
}

func TestPolicyMatchesPublicEnvelope(t *testing.T) {
	privatePolicy := fixturePolicy()
	rulesHash, err := policy.RulesHash(privatePolicy)
	if err != nil {
		t.Fatal(err)
	}
	chainScopeHash, err := policy.ChainScopeHash(privatePolicy)
	if err != nil {
		t.Fatal(err)
	}

	envelope := protocol.PolicyEnvelope{
		ProtocolVersion: protocol.CurrentProtocolVersion,
		SchemaVersion:   policy.CurrentSchemaVersion,
		PolicyID:        privatePolicy.PolicyID,
		Owner:           privatePolicy.Owner,
		Account:         privatePolicy.Account,
		PolicyVersion:   privatePolicy.Version,
		ValidAfter:      privatePolicy.ValidAfter,
		ValidUntil:      privatePolicy.ValidUntil,
		ChainScopeHash:  chainScopeHash,
		RulesHash:       rulesHash,
		MetadataHash:    common.HexToHash("0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
	}

	if _, err := policy.ValidateAgainstEnvelope(privatePolicy, envelope); err != nil {
		t.Fatalf("valid policy rejected: %v", err)
	}

	privatePolicy.MaxNativeValue = "999"
	if _, err := policy.ValidateAgainstEnvelope(privatePolicy, envelope); err == nil {
		t.Fatal("mutated private rules matched the old public commitment")
	}
}

func TestDuplicateTargetsRejected(t *testing.T) {
	privatePolicy := fixturePolicy()
	privatePolicy.Targets = append(privatePolicy.Targets, privatePolicy.Targets[0])

	if _, err := policy.Normalize(privatePolicy); err == nil {
		t.Fatal("duplicate target was accepted")
	}
}

func fixturePolicy() policy.PrivatePolicy {
	return policy.PrivatePolicy{
		SchemaVersion:   policy.CurrentSchemaVersion,
		PolicyID:        common.HexToHash("0x1111111111111111111111111111111111111111111111111111111111111111"),
		Owner:           common.HexToAddress("0x1111111111111111111111111111111111111111"),
		Account:         common.HexToAddress("0x2222222222222222222222222222222222222222"),
		Version:         1,
		ValidAfter:      100,
		ValidUntil:      10_000,
		AllowedChainIDs: []string{"114", "14"},
		AuthorizedAgents: []common.Address{
			common.HexToAddress("0x4444444444444444444444444444444444444444"),
			common.HexToAddress("0x3333333333333333333333333333333333333333"),
		},
		MaxNativeValue:              "1000000000000000000",
		MaxRiskScore:                0,
		MaxSimulationBlockAge:       64,
		RequireSuccessfulSimulation: true,
		RequireProviderAgreement:    true,
		Targets: []policy.TargetRule{
			{
				Target:                 common.HexToAddress("0x5555555555555555555555555555555555555555"),
				CodeHash:               common.HexToHash("0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
				Selectors:              []string{"0xa9059cbb", "0x095ea7b3"},
				MaxNativeValue:         "0",
				MaxERC20Transfer:       "100000000",
				MaxERC20Approval:       "100000000",
				AllowUnlimitedApproval: false,
				AllowedRecipients: []common.Address{
					common.HexToAddress("0x7777777777777777777777777777777777777777"),
					common.HexToAddress("0x6666666666666666666666666666666666666666"),
				},
			},
		},
	}
}
