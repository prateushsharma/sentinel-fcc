package protocol_test

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"testing"

	"extension-scaffold/internal/protocolvectors"
	"extension-scaffold/pkg/protocol"
)

func committedVectorPath(t *testing.T) string {
	t.Helper()
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("resolve test source path")
	}
	return filepath.Clean(filepath.Join(filepath.Dir(file), "../../../testdata/protocol/v1.json"))
}

func TestCommittedVectorMatchesCanonicalGenerator(t *testing.T) {
	expectedBytes, err := os.ReadFile(committedVectorPath(t))
	if err != nil {
		t.Fatalf("read committed vector: %v", err)
	}

	var expected protocolvectors.Vector
	if err := json.Unmarshal(expectedBytes, &expected); err != nil {
		t.Fatalf("decode committed vector: %v", err)
	}

	actual, err := protocolvectors.Build()
	if err != nil {
		t.Fatalf("build vector: %v", err)
	}

	if !reflect.DeepEqual(expected, actual) {
		t.Fatalf("committed vector differs from generator\nexpected: %#v\nactual: %#v", expected, actual)
	}
}

func TestIntentHashChangesWhenCalldataChanges(t *testing.T) {
	fixture, err := protocolvectors.BuildFixture()
	if err != nil {
		t.Fatal(err)
	}

	original, err := protocol.HashTransactionIntent(fixture.Intent)
	if err != nil {
		t.Fatal(err)
	}

	mutated := fixture.Intent
	mutated.Data = bytes.Clone(fixture.Intent.Data)
	mutated.Data[len(mutated.Data)-1] ^= 0x01

	changed, err := protocol.HashTransactionIntent(mutated)
	if err != nil {
		t.Fatal(err)
	}

	if original == changed {
		t.Fatal("changing one calldata byte did not change the intent hash")
	}
}

func TestIntentHashChangesWhenExecutionScopeChanges(t *testing.T) {
	fixture, err := protocolvectors.BuildFixture()
	if err != nil {
		t.Fatal(err)
	}

	original, err := protocol.HashTransactionIntent(fixture.Intent)
	if err != nil {
		t.Fatal(err)
	}

	mutated := fixture.Intent
	mutated.Nonce++

	changed, err := protocol.HashTransactionIntent(mutated)
	if err != nil {
		t.Fatal(err)
	}

	if original == changed {
		t.Fatal("changing nonce did not change the intent hash")
	}
}
