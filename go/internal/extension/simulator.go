package extension

import (
	"context"

	"extension-scaffold/internal/simulation"
	"extension-scaffold/pkg/protocol"
)

type intentSimulator interface {
	Simulate(context.Context, protocol.TransactionIntent) (simulation.Result, error)
}
