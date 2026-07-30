package simulation

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"
	"sync"

	"extension-scaffold/internal/policyengine"
	"extension-scaffold/pkg/protocol"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
)

type headerObservation struct {
	provider *rpcProvider
	header   blockHeader
	number   uint64
	err      error
}

type providerSimulation struct {
	provider       *rpcProvider
	blockHash      common.Hash
	effects        NormalizedEffects
	effectsHash    common.Hash
	success        bool
	targetCodeHash common.Hash
	consensusHash  common.Hash
	err            error
}

type consensusPreimage struct {
	EffectsHash    common.Hash `json:"effectsHash"`
	Success        bool        `json:"success"`
	TargetCodeHash common.Hash `json:"targetCodeHash"`
}

type disagreementPreimage struct {
	Version     uint16        `json:"version"`
	BlockNumber uint64        `json:"blockNumber"`
	BlockHash   common.Hash   `json:"blockHash"`
	Digests     []common.Hash `json:"digests"`
}

// Simulate anchors providers to one historical block and requires matching effects.
func (simulator *QuorumSimulator) Simulate(
	parent context.Context,
	intent protocol.TransactionIntent,
) (Result, error) {
	if err := protocol.ValidateTransactionIntent(intent); err != nil {
		return Result{}, fmt.Errorf("validate simulation intent: %w", err)
	}

	ctx, cancel := context.WithTimeout(parent, simulator.timeout)
	defer cancel()

	latest := simulator.observeHeaders(ctx, "latest", simulator.providers)
	successfulLatest := make([]headerObservation, 0, len(latest))
	for _, observation := range latest {
		if observation.err == nil {
			successfulLatest = append(successfulLatest, observation)
		}
	}
	if len(successfulLatest) < simulator.quorum {
		return Result{}, fmt.Errorf(
			"only %d of %d providers returned a latest block; quorum is %d",
			len(successfulLatest),
			len(simulator.providers),
			simulator.quorum,
		)
	}

	minimumLatest := successfulLatest[0].number
	for _, observation := range successfulLatest[1:] {
		if observation.number < minimumLatest {
			minimumLatest = observation.number
		}
	}
	if minimumLatest == 0 {
		return Result{}, fmt.Errorf("cannot select a historical block before genesis")
	}

	anchorNumber := minimumLatest - 1
	anchorTag := encodeBlockNumber(anchorNumber)

	candidates := make([]*rpcProvider, len(successfulLatest))
	for index, observation := range successfulLatest {
		candidates[index] = observation.provider
	}

	anchors := simulator.observeHeaders(ctx, anchorTag, candidates)
	hashGroups := make(map[common.Hash][]*rpcProvider)
	for _, observation := range anchors {
		if observation.err == nil && observation.number == anchorNumber {
			hashGroups[observation.header.Hash] = append(
				hashGroups[observation.header.Hash],
				observation.provider,
			)
		}
	}

	anchorHash, anchoredProviders, ok := largestHeaderGroup(hashGroups)
	if !ok || len(anchoredProviders) < simulator.quorum {
		return Result{}, fmt.Errorf(
			"providers could not establish canonical block %d with quorum %d",
			anchorNumber,
			simulator.quorum,
		)
	}

	simulations := simulator.simulateProviders(
		ctx,
		anchoredProviders,
		intent,
		anchorTag,
		anchorHash,
	)

	successful := make([]providerSimulation, 0, len(simulations))
	consensusGroups := make(map[common.Hash][]providerSimulation)
	for _, result := range simulations {
		if result.err != nil {
			continue
		}
		successful = append(successful, result)
		consensusGroups[result.consensusHash] = append(
			consensusGroups[result.consensusHash],
			result,
		)
	}
	if len(successful) < simulator.quorum {
		return Result{}, fmt.Errorf(
			"only %d providers completed simulation; quorum is %d",
			len(successful),
			simulator.quorum,
		)
	}

	_, agreed, agreement := largestSimulationGroup(consensusGroups)
	if agreement && len(agreed) >= simulator.quorum {
		chosen := agreed[0]
		return Result{
			Snapshot: policyengine.SimulationSnapshot{
				IntentHash:          mustIntentHash(intent),
				BlockNumber:         anchorNumber,
				BlockHash:           anchorHash,
				ObservedBlockNumber: minimumLatest,
				EffectsHash:         chosen.effectsHash,
				Success:             chosen.success,
				ProviderAgreement:   true,
				TargetCodeHash:      chosen.targetCodeHash,
			},
			Effects: chosen.effects,
		}, nil
	}

	disagreementHash, err := hashDisagreement(anchorNumber, anchorHash, successful)
	if err != nil {
		return Result{}, err
	}
	return Result{
		Snapshot: policyengine.SimulationSnapshot{
			IntentHash:          mustIntentHash(intent),
			BlockNumber:         anchorNumber,
			BlockHash:           anchorHash,
			ObservedBlockNumber: minimumLatest,
			EffectsHash:         disagreementHash,
			Success:             false,
			ProviderAgreement:   false,
			TargetCodeHash:      common.Hash{},
		},
		Effects: NormalizedEffects{
			Version: effectsVersion,
			Success: false,
		},
	}, nil
}

func (simulator *QuorumSimulator) observeHeaders(
	ctx context.Context,
	block string,
	providers []*rpcProvider,
) []headerObservation {
	results := make(chan headerObservation, len(providers))
	var waitGroup sync.WaitGroup
	waitGroup.Add(len(providers))

	for _, provider := range providers {
		provider := provider
		go func() {
			defer waitGroup.Done()
			header, err := provider.header(ctx, block)
			observation := headerObservation{
				provider: provider,
				header:   header,
				err:      err,
			}
			if err == nil {
				observation.number, observation.err = parseHexUint64(header.Number)
			}
			results <- observation
		}()
	}

	waitGroup.Wait()
	close(results)

	observations := make([]headerObservation, 0, len(providers))
	for result := range results {
		observations = append(observations, result)
	}
	sort.Slice(observations, func(i, j int) bool {
		return observations[i].provider.index < observations[j].provider.index
	})
	return observations
}

func (simulator *QuorumSimulator) simulateProviders(
	ctx context.Context,
	providers []*rpcProvider,
	intent protocol.TransactionIntent,
	blockTag string,
	anchorHash common.Hash,
) []providerSimulation {
	results := make(chan providerSimulation, len(providers))
	var waitGroup sync.WaitGroup
	waitGroup.Add(len(providers))

	for _, provider := range providers {
		provider := provider
		go func() {
			defer waitGroup.Done()
			results <- simulateProvider(ctx, provider, intent, blockTag, anchorHash)
		}()
	}

	waitGroup.Wait()
	close(results)

	simulations := make([]providerSimulation, 0, len(providers))
	for result := range results {
		simulations = append(simulations, result)
	}
	sort.Slice(simulations, func(i, j int) bool {
		return simulations[i].provider.index < simulations[j].provider.index
	})
	return simulations
}

func simulateProvider(
	ctx context.Context,
	provider *rpcProvider,
	intent protocol.TransactionIntent,
	blockTag string,
	anchorHash common.Hash,
) providerSimulation {
	result := providerSimulation{provider: provider}

	trace, err := provider.trace(ctx, intent, blockTag)
	if err != nil {
		result.err = err
		return result
	}
	code, err := provider.code(ctx, intent.Target, blockTag)
	if err != nil {
		result.err = err
		return result
	}

	headerAfter, err := provider.header(ctx, blockTag)
	if err != nil {
		result.err = err
		return result
	}
	if headerAfter.Hash != anchorHash {
		result.err = fmt.Errorf("provider %d reorged during simulation", provider.index)
		return result
	}

	effects, effectsHash, err := normalizeTrace(trace)
	if err != nil {
		result.err = fmt.Errorf("normalize provider %d trace: %w", provider.index, err)
		return result
	}

	result.blockHash = anchorHash
	result.effects = effects
	result.effectsHash = effectsHash
	result.success = effects.Success
	result.targetCodeHash = crypto.Keccak256Hash(code)

	encoded, err := json.Marshal(consensusPreimage{
		EffectsHash:    result.effectsHash,
		Success:        result.success,
		TargetCodeHash: result.targetCodeHash,
	})
	if err != nil {
		result.err = fmt.Errorf("marshal provider consensus preimage: %w", err)
		return result
	}
	result.consensusHash = crypto.Keccak256Hash(encoded)
	return result
}

func largestHeaderGroup(
	groups map[common.Hash][]*rpcProvider,
) (common.Hash, []*rpcProvider, bool) {
	var selectedHash common.Hash
	var selected []*rpcProvider

	hashes := make([]common.Hash, 0, len(groups))
	for hash := range groups {
		hashes = append(hashes, hash)
	}
	sort.Slice(hashes, func(i, j int) bool {
		return string(hashes[i][:]) < string(hashes[j][:])
	})

	for _, hash := range hashes {
		group := groups[hash]
		if len(group) > len(selected) {
			selectedHash = hash
			selected = group
		}
	}
	return selectedHash, selected, len(selected) > 0
}

func largestSimulationGroup(
	groups map[common.Hash][]providerSimulation,
) (common.Hash, []providerSimulation, bool) {
	var selectedHash common.Hash
	var selected []providerSimulation

	hashes := make([]common.Hash, 0, len(groups))
	for hash := range groups {
		hashes = append(hashes, hash)
	}
	sort.Slice(hashes, func(i, j int) bool {
		return string(hashes[i][:]) < string(hashes[j][:])
	})

	for _, hash := range hashes {
		group := groups[hash]
		if len(group) > len(selected) {
			selectedHash = hash
			selected = group
		}
	}
	return selectedHash, selected, len(selected) > 0
}

func hashDisagreement(
	blockNumber uint64,
	blockHash common.Hash,
	results []providerSimulation,
) (common.Hash, error) {
	digests := make([]common.Hash, len(results))
	for index, result := range results {
		digests[index] = result.consensusHash
	}
	sort.Slice(digests, func(i, j int) bool {
		return string(digests[i][:]) < string(digests[j][:])
	})

	encoded, err := json.Marshal(disagreementPreimage{
		Version:     1,
		BlockNumber: blockNumber,
		BlockHash:   blockHash,
		Digests:     digests,
	})
	if err != nil {
		return common.Hash{}, fmt.Errorf("marshal disagreement evidence: %w", err)
	}
	return crypto.Keccak256Hash(encoded), nil
}

func mustIntentHash(intent protocol.TransactionIntent) common.Hash {
	hash, err := protocol.HashTransactionIntent(intent)
	if err != nil {
		panic(err)
	}
	return hash
}

func encodeBlockNumber(number uint64) string {
	return fmt.Sprintf("0x%x", number)
}
