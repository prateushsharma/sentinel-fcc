package policyengine

import (
	"encoding/hex"
	"fmt"
	"math/big"

	"github.com/ethereum/go-ethereum/common"
)

const (
	selectorApprove      = "0x095ea7b3"
	selectorTransfer     = "0xa9059cbb"
	selectorTransferFrom = "0x23b872dd"
)

type tokenOperation struct {
	selector  string
	recipient common.Address
	amount    *big.Int
	known     bool
}

func selectorFromCalldata(data []byte) (string, error) {
	switch {
	case len(data) == 0:
		return "0x00000000", nil
	case len(data) < 4:
		return "", fmt.Errorf("calldata shorter than selector")
	default:
		return "0x" + hex.EncodeToString(data[:4]), nil
	}
}

func addressWord(data []byte, offset int) (common.Address, error) {
	if offset < 0 || len(data) < offset+32 {
		return common.Address{}, fmt.Errorf("missing ABI address word")
	}
	var address common.Address
	copy(address[:], data[offset+12:offset+32])
	return address, nil
}

func uintWord(data []byte, offset int) (*big.Int, error) {
	if offset < 0 || len(data) < offset+32 {
		return nil, fmt.Errorf("missing ABI uint256 word")
	}
	return new(big.Int).SetBytes(data[offset : offset+32]), nil
}

func decodeTokenOperation(data []byte, selector string) (tokenOperation, error) {
	switch selector {
	case selectorApprove, selectorTransfer:
		if len(data) != 68 {
			return tokenOperation{}, fmt.Errorf("expected 68-byte ERC20 calldata")
		}
		recipient, err := addressWord(data, 4)
		if err != nil {
			return tokenOperation{}, err
		}
		amount, err := uintWord(data, 36)
		if err != nil {
			return tokenOperation{}, err
		}
		return tokenOperation{
			selector:  selector,
			recipient: recipient,
			amount:    amount,
			known:     true,
		}, nil

	case selectorTransferFrom:
		if len(data) != 100 {
			return tokenOperation{}, fmt.Errorf("expected 100-byte ERC20 calldata")
		}
		recipient, err := addressWord(data, 36)
		if err != nil {
			return tokenOperation{}, err
		}
		amount, err := uintWord(data, 68)
		if err != nil {
			return tokenOperation{}, err
		}
		return tokenOperation{
			selector:  selector,
			recipient: recipient,
			amount:    amount,
			known:     true,
		}, nil

	default:
		return tokenOperation{selector: selector}, nil
	}
}
