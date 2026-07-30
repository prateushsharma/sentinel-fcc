package extension

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestNodeDecryptorUsesBase64JSONWireFormat(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		var payload decryptRequest
		if err := json.NewDecoder(request.Body).Decode(&payload); err != nil {
			t.Fatal(err)
		}
		if string(payload.EncryptedMessage) != "ciphertext" {
			t.Fatalf("unexpected ciphertext: %q", payload.EncryptedMessage)
		}
		_ = json.NewEncoder(writer).Encode(decryptResponse{
			DecryptedMessage: []byte("plaintext"),
		})
	}))
	defer server.Close()

	decryptor := &nodeDecryptor{
		endpoint: server.URL,
		client:   server.Client(),
	}
	plaintext, err := decryptor.Decrypt(context.Background(), []byte("ciphertext"))
	if err != nil {
		t.Fatal(err)
	}
	if string(plaintext) != "plaintext" {
		t.Fatalf("unexpected plaintext: %q", plaintext)
	}
}
