package verify_test

import (
	"crypto/ed25519"
	"encoding/pem"
	"os"
	"path/filepath"
	"testing"

	"github.com/zoncaesaradmin/appliance-release/internal/verify"
)

func generateKey(t *testing.T, id string) (verify.PublicKey, ed25519.PrivateKey) {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	return verify.PublicKey{ID: id, Key: pub}, priv
}

func TestVerifySignature_Valid(t *testing.T) {
	pub, priv := generateKey(t, "release-signing-key")
	data := []byte("release manifest bytes")
	sig := ed25519.Sign(priv, data)

	if err := verify.VerifySignature(pub, data, sig); err != nil {
		t.Errorf("expected valid signature to verify, got: %v", err)
	}
}

// Tamper: the signature was valid for the original bytes, not these.
func TestVerifySignature_TamperedData(t *testing.T) {
	pub, priv := generateKey(t, "release-signing-key")
	sig := ed25519.Sign(priv, []byte("release manifest bytes"))

	if err := verify.VerifySignature(pub, []byte("tampered manifest bytes"), sig); err == nil {
		t.Error("expected signature over tampered data to fail verification")
	}
}

// Wrong identity: signed by a key that is not the pinned release key.
func TestVerifySignature_WrongSignerIdentity(t *testing.T) {
	pinnedPub, _ := generateKey(t, "release-signing-key")
	_, attackerPriv := generateKey(t, "attacker-key")

	data := []byte("release manifest bytes")
	sig := ed25519.Sign(attackerPriv, data)

	if err := verify.VerifySignature(pinnedPub, data, sig); err == nil {
		t.Error("expected signature from an unpinned key to fail verification")
	}
}

func TestLoadPublicKey_PEM(t *testing.T) {
	pub, _, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}

	path := filepath.Join(t.TempDir(), "release-signing.pub")
	block := &pem.Block{Type: "PUBLIC KEY", Bytes: pub}
	if err := os.WriteFile(path, pem.EncodeToMemory(block), 0o644); err != nil {
		t.Fatal(err)
	}

	loaded, err := verify.LoadPublicKey("release-signing-key", path)
	if err != nil {
		t.Fatal(err)
	}
	if !loaded.Key.Equal(pub) {
		t.Error("loaded public key does not match the original")
	}
	if loaded.ID != "release-signing-key" {
		t.Errorf("expected ID to be preserved, got %q", loaded.ID)
	}
}

func TestLoadPublicKey_MissingEvidence(t *testing.T) {
	if _, err := verify.LoadPublicKey("release-signing-key", filepath.Join(t.TempDir(), "missing.pub")); err == nil {
		t.Error("expected missing public key file to fail")
	}
}
