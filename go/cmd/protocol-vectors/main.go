package main

import (
	"encoding/json"
	"fmt"
	"os"

	"extension-scaffold/internal/protocolvectors"
)

func main() {
	vector, err := protocolvectors.Build()
	if err != nil {
		fmt.Fprintf(os.Stderr, "build protocol vector: %v\n", err)
		os.Exit(1)
	}

	encoder := json.NewEncoder(os.Stdout)
	encoder.SetEscapeHTML(false)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(vector); err != nil {
		fmt.Fprintf(os.Stderr, "encode protocol vector: %v\n", err)
		os.Exit(1)
	}
}
