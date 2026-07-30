package extension

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

const (
	maxEncryptedRequestBytes = 256 * 1024
	maxDecryptedRequestBytes = 1024 * 1024
	decryptRequestTimeout    = 5 * time.Second
)

type requestDecryptor interface {
	Decrypt(context.Context, []byte) ([]byte, error)
}

type nodeDecryptor struct {
	endpoint string
	client   *http.Client
}

type decryptRequest struct {
	EncryptedMessage []byte `json:"encryptedMessage"`
}

type decryptResponse struct {
	DecryptedMessage []byte `json:"decryptedMessage"`
}

func newNodeDecryptor(signPort int) requestDecryptor {
	return &nodeDecryptor{
		endpoint: fmt.Sprintf("http://127.0.0.1:%d/decrypt", signPort),
		client: &http.Client{
			Timeout: decryptRequestTimeout,
		},
	}
}

func (decryptor *nodeDecryptor) Decrypt(
	ctx context.Context,
	ciphertext []byte,
) ([]byte, error) {
	if len(ciphertext) == 0 {
		return nil, fmt.Errorf("encrypted request must not be empty")
	}
	if len(ciphertext) > maxEncryptedRequestBytes {
		return nil, fmt.Errorf("encrypted request exceeds %d bytes", maxEncryptedRequestBytes)
	}

	body, err := json.Marshal(decryptRequest{EncryptedMessage: ciphertext})
	if err != nil {
		return nil, fmt.Errorf("encode decrypt request: %w", err)
	}

	request, err := http.NewRequestWithContext(
		ctx,
		http.MethodPost,
		decryptor.endpoint,
		bytes.NewReader(body),
	)
	if err != nil {
		return nil, fmt.Errorf("create decrypt request: %w", err)
	}
	request.Header.Set("Content-Type", "application/json")

	response, err := decryptor.client.Do(request)
	if err != nil {
		return nil, fmt.Errorf("call tee-node decrypt endpoint: %w", err)
	}
	defer response.Body.Close()

	if response.StatusCode != http.StatusOK {
		message, _ := io.ReadAll(io.LimitReader(response.Body, 4*1024))
		return nil, fmt.Errorf(
			"tee-node decrypt endpoint returned %d: %s",
			response.StatusCode,
			string(message),
		)
	}

	var decoded decryptResponse
	decoder := json.NewDecoder(io.LimitReader(response.Body, maxDecryptedRequestBytes))
	if err := decoder.Decode(&decoded); err != nil {
		return nil, fmt.Errorf("decode tee-node decrypt response: %w", err)
	}
	if len(decoded.DecryptedMessage) == 0 {
		return nil, fmt.Errorf("tee-node returned empty plaintext")
	}
	if len(decoded.DecryptedMessage) >= maxDecryptedRequestBytes {
		return nil, fmt.Errorf("decrypted request exceeds limit")
	}

	return decoded.DecryptedMessage, nil
}
