package policy

import (
	"errors"
	"fmt"
	"math/big"
)

var ErrInvalidUint256 = errors.New("invalid canonical uint256")

// ParseUint256 parses a canonical base-10 uint256 string.
func ParseUint256(value string) (*big.Int, error) {
	if value == "" {
		return nil, fmt.Errorf("%w: empty string", ErrInvalidUint256)
	}
	if len(value) > 1 && value[0] == '0' {
		return nil, fmt.Errorf("%w: leading zero", ErrInvalidUint256)
	}

	for _, char := range value {
		if char < '0' || char > '9' {
			return nil, fmt.Errorf("%w: non-decimal character", ErrInvalidUint256)
		}
	}

	parsed, ok := new(big.Int).SetString(value, 10)
	if !ok || parsed.Sign() < 0 || parsed.BitLen() > 256 {
		return nil, ErrInvalidUint256
	}
	return parsed, nil
}
