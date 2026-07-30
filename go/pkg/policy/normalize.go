package policy

import (
	"bytes"
	"encoding/hex"
	"errors"
	"fmt"
	"math/big"
	"sort"
	"strings"

	"github.com/ethereum/go-ethereum/common"
)

var (
	ErrDuplicateValue     = errors.New("duplicate policy value")
	ErrInvalidSelector    = errors.New("invalid selector")
	ErrInvalidPolicy      = errors.New("invalid private policy")
	ErrInvalidPolicyChain = errors.New("invalid policy chain")
)

func normalizeDecimal(value string) (string, *big.Int, error) {
	parsed, err := ParseUint256(value)
	if err != nil {
		return "", nil, err
	}
	return parsed.String(), parsed, nil
}

func normalizeSelector(value string) (string, error) {
	if len(value) != 10 || !strings.HasPrefix(value, "0x") {
		return "", ErrInvalidSelector
	}

	decoded, err := hex.DecodeString(value[2:])
	if err != nil || len(decoded) != 4 {
		return "", ErrInvalidSelector
	}
	return "0x" + hex.EncodeToString(decoded), nil
}

func sortAddresses(values []common.Address) {
	sort.Slice(values, func(i, j int) bool {
		return bytes.Compare(values[i][:], values[j][:]) < 0
	})
}

func sortHashes(values []common.Hash) {
	sort.Slice(values, func(i, j int) bool {
		return bytes.Compare(values[i][:], values[j][:]) < 0
	})
}

func ensureUniqueAddresses(name string, values []common.Address) error {
	for index, value := range values {
		if value == (common.Address{}) {
			return fmt.Errorf("%s[%d]: zero address: %w", name, index, ErrInvalidPolicy)
		}
		if index > 0 && value == values[index-1] {
			return fmt.Errorf("%s: %w", name, ErrDuplicateValue)
		}
	}
	return nil
}

func normalizeChainIDs(values []string) ([]string, error) {
	type chainValue struct {
		text  string
		value *big.Int
	}

	chains := make([]chainValue, 0, len(values))
	for index, raw := range values {
		canonical, parsed, err := normalizeDecimal(raw)
		if err != nil || parsed.Sign() == 0 {
			return nil, fmt.Errorf("allowedChainIds[%d]: %w", index, ErrInvalidPolicyChain)
		}
		chains = append(chains, chainValue{text: canonical, value: parsed})
	}

	sort.Slice(chains, func(i, j int) bool {
		return chains[i].value.Cmp(chains[j].value) < 0
	})

	normalized := make([]string, len(chains))
	for index, chain := range chains {
		if index > 0 && chain.value.Cmp(chains[index-1].value) == 0 {
			return nil, fmt.Errorf("allowedChainIds: %w", ErrDuplicateValue)
		}
		normalized[index] = chain.text
	}
	return normalized, nil
}

func normalizeTarget(rule TargetRule, globalMax *big.Int) (TargetRule, error) {
	if rule.Target == (common.Address{}) {
		return TargetRule{}, fmt.Errorf("target: %w", ErrInvalidPolicy)
	}

	maxNative, parsedNative, err := normalizeDecimal(rule.MaxNativeValue)
	if err != nil {
		return TargetRule{}, fmt.Errorf("target %s maxNativeValue: %w", rule.Target.Hex(), err)
	}
	if parsedNative.Cmp(globalMax) > 0 {
		return TargetRule{}, fmt.Errorf(
			"target %s maxNativeValue exceeds global maximum: %w",
			rule.Target.Hex(),
			ErrInvalidPolicy,
		)
	}

	maxTransfer, _, err := normalizeDecimal(rule.MaxERC20Transfer)
	if err != nil {
		return TargetRule{}, fmt.Errorf("target %s maxErc20Transfer: %w", rule.Target.Hex(), err)
	}

	maxApproval, _, err := normalizeDecimal(rule.MaxERC20Approval)
	if err != nil {
		return TargetRule{}, fmt.Errorf("target %s maxErc20Approval: %w", rule.Target.Hex(), err)
	}

	selectors := append([]string(nil), rule.Selectors...)
	for index, selector := range selectors {
		normalized, err := normalizeSelector(selector)
		if err != nil {
			return TargetRule{}, fmt.Errorf(
				"target %s selectors[%d]: %w",
				rule.Target.Hex(),
				index,
				err,
			)
		}
		selectors[index] = normalized
	}
	sort.Strings(selectors)
	for index := 1; index < len(selectors); index++ {
		if selectors[index] == selectors[index-1] {
			return TargetRule{}, fmt.Errorf(
				"target %s selectors: %w",
				rule.Target.Hex(),
				ErrDuplicateValue,
			)
		}
	}
	if !rule.AllowAnySelector && len(selectors) == 0 {
		return TargetRule{}, fmt.Errorf(
			"target %s has no allowed selectors: %w",
			rule.Target.Hex(),
			ErrInvalidPolicy,
		)
	}

	recipients := append([]common.Address(nil), rule.AllowedRecipients...)
	sortAddresses(recipients)
	if err := ensureUniqueAddresses("allowedRecipients", recipients); err != nil {
		return TargetRule{}, fmt.Errorf("target %s: %w", rule.Target.Hex(), err)
	}

	return TargetRule{
		Target:                 rule.Target,
		CodeHash:               rule.CodeHash,
		AllowAnySelector:       rule.AllowAnySelector,
		Selectors:              selectors,
		MaxNativeValue:         maxNative,
		MaxERC20Transfer:       maxTransfer,
		MaxERC20Approval:       maxApproval,
		AllowUnlimitedApproval: rule.AllowUnlimitedApproval,
		AllowedRecipients:      recipients,
	}, nil
}

// Normalize validates a policy and returns a deeply copied canonical form.
func Normalize(input PrivatePolicy) (PrivatePolicy, error) {
	if input.SchemaVersion != CurrentSchemaVersion {
		return PrivatePolicy{}, fmt.Errorf("schemaVersion: %w", ErrInvalidPolicy)
	}
	if input.PolicyID == (common.Hash{}) {
		return PrivatePolicy{}, fmt.Errorf("policyId: %w", ErrInvalidPolicy)
	}
	if input.Owner == (common.Address{}) {
		return PrivatePolicy{}, fmt.Errorf("owner: %w", ErrInvalidPolicy)
	}
	if input.Account == (common.Address{}) {
		return PrivatePolicy{}, fmt.Errorf("account: %w", ErrInvalidPolicy)
	}
	if input.Version == 0 {
		return PrivatePolicy{}, fmt.Errorf("version: %w", ErrInvalidPolicy)
	}
	if input.ValidUntil == 0 || input.ValidAfter > input.ValidUntil {
		return PrivatePolicy{}, fmt.Errorf("validity window: %w", ErrInvalidPolicy)
	}
	if input.MaxRiskScore > MaximumRiskScore {
		return PrivatePolicy{}, fmt.Errorf("maxRiskScore: %w", ErrInvalidPolicy)
	}
	if input.MaxSimulationBlockAge == 0 || input.MaxSimulationBlockAge > 255 {
		return PrivatePolicy{}, fmt.Errorf("maxSimulationBlockAge: %w", ErrInvalidPolicy)
	}
	if len(input.AllowedChainIDs) == 0 {
		return PrivatePolicy{}, fmt.Errorf("allowedChainIds: %w", ErrInvalidPolicy)
	}
	if len(input.AuthorizedAgents) == 0 {
		return PrivatePolicy{}, fmt.Errorf("authorizedAgents: %w", ErrInvalidPolicy)
	}
	if len(input.Targets) == 0 {
		return PrivatePolicy{}, fmt.Errorf("targets: %w", ErrInvalidPolicy)
	}

	globalMax, parsedGlobalMax, err := normalizeDecimal(input.MaxNativeValue)
	if err != nil {
		return PrivatePolicy{}, fmt.Errorf("maxNativeValue: %w", err)
	}

	chains, err := normalizeChainIDs(input.AllowedChainIDs)
	if err != nil {
		return PrivatePolicy{}, err
	}

	agents := append([]common.Address(nil), input.AuthorizedAgents...)
	sortAddresses(agents)
	if err := ensureUniqueAddresses("authorizedAgents", agents); err != nil {
		return PrivatePolicy{}, err
	}

	targets := make([]TargetRule, len(input.Targets))
	for index, target := range input.Targets {
		normalized, err := normalizeTarget(target, parsedGlobalMax)
		if err != nil {
			return PrivatePolicy{}, err
		}
		targets[index] = normalized
	}
	sort.Slice(targets, func(i, j int) bool {
		return bytes.Compare(targets[i].Target[:], targets[j].Target[:]) < 0
	})
	for index := 1; index < len(targets); index++ {
		if targets[index].Target == targets[index-1].Target {
			return PrivatePolicy{}, fmt.Errorf("targets: %w", ErrDuplicateValue)
		}
	}

	return PrivatePolicy{
		SchemaVersion:               input.SchemaVersion,
		PolicyID:                    input.PolicyID,
		Owner:                       input.Owner,
		Account:                     input.Account,
		Version:                     input.Version,
		ValidAfter:                  input.ValidAfter,
		ValidUntil:                  input.ValidUntil,
		AllowedChainIDs:             chains,
		AuthorizedAgents:            agents,
		MaxNativeValue:              globalMax,
		MaxRiskScore:                input.MaxRiskScore,
		MaxSimulationBlockAge:       input.MaxSimulationBlockAge,
		RequireSuccessfulSimulation: input.RequireSuccessfulSimulation,
		RequireProviderAgreement:    input.RequireProviderAgreement,
		Targets:                     targets,
	}, nil
}

// FindTarget returns the normalized rule for target.
func FindTarget(normalized PrivatePolicy, target common.Address) (TargetRule, bool) {
	index := sort.Search(len(normalized.Targets), func(index int) bool {
		return bytes.Compare(normalized.Targets[index].Target[:], target[:]) >= 0
	})
	if index < len(normalized.Targets) && normalized.Targets[index].Target == target {
		return normalized.Targets[index], true
	}
	return TargetRule{}, false
}

// HasAuthorizedAgent reports whether agent is in the normalized allowlist.
func HasAuthorizedAgent(normalized PrivatePolicy, agent common.Address) bool {
	index := sort.Search(len(normalized.AuthorizedAgents), func(index int) bool {
		return bytes.Compare(normalized.AuthorizedAgents[index][:], agent[:]) >= 0
	})
	return index < len(normalized.AuthorizedAgents) && normalized.AuthorizedAgents[index] == agent
}

// HasAllowedRecipient reports whether recipient is allowed. An empty list means
// the target rule does not restrict recipients.
func HasAllowedRecipient(rule TargetRule, recipient common.Address) bool {
	if len(rule.AllowedRecipients) == 0 {
		return true
	}
	index := sort.Search(len(rule.AllowedRecipients), func(index int) bool {
		return bytes.Compare(rule.AllowedRecipients[index][:], recipient[:]) >= 0
	})
	return index < len(rule.AllowedRecipients) && rule.AllowedRecipients[index] == recipient
}

// HasSelector reports whether selector is allowed by the normalized rule.
func HasSelector(rule TargetRule, selector string) bool {
	if rule.AllowAnySelector {
		return true
	}
	index := sort.SearchStrings(rule.Selectors, selector)
	return index < len(rule.Selectors) && rule.Selectors[index] == selector
}
