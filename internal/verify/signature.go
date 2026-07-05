package verify

import (
	"crypto/ed25519"
	"encoding/pem"
	"fmt"
	"os"
)

// PublicKey wraps a pinned ed25519 verification key together with the
// identifier used for allowlist and provenance-identity matching.
type PublicKey struct {
	ID  string
	Key ed25519.PublicKey
}

// LoadPublicKey reads a PEM-encoded ed25519 public key from path. This is
// the small pinned public key that bootstraps all other verification
// (see Security And Supply Chain in docs/release-plan.md).
func LoadPublicKey(id, path string) (PublicKey, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return PublicKey{}, fmt.Errorf("verify: read public key %s: %w", path, err)
	}

	block, _ := pem.Decode(data)
	if block == nil {
		return PublicKey{}, fmt.Errorf("verify: %s is not PEM-encoded", path)
	}
	if len(block.Bytes) != ed25519.PublicKeySize {
		return PublicKey{}, fmt.Errorf("verify: %s is not a valid ed25519 public key", path)
	}

	return PublicKey{ID: id, Key: ed25519.PublicKey(block.Bytes)}, nil
}

// VerifySignature verifies a raw ed25519 detached signature over data.
// It fails closed on a malformed key, wrong-length signature, or
// signature that does not verify.
func VerifySignature(pub PublicKey, data, sig []byte) error {
	if len(pub.Key) != ed25519.PublicKeySize {
		return fmt.Errorf("verify: public key %q has invalid length", pub.ID)
	}
	if len(sig) != ed25519.SignatureSize {
		return fmt.Errorf("verify: signature has invalid length %d", len(sig))
	}
	if !ed25519.Verify(pub.Key, data, sig) {
		return fmt.Errorf("verify: signature does not verify against key %q", pub.ID)
	}
	return nil
}

// VerifyFileSignature verifies the detached signature at sigPath over the
// file at path.
func VerifyFileSignature(pub PublicKey, path, sigPath string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("verify: read %s: %w", path, err)
	}
	sig, err := os.ReadFile(sigPath)
	if err != nil {
		return fmt.Errorf("verify: read signature %s: %w", sigPath, err)
	}
	return VerifySignature(pub, data, sig)
}
