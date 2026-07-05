package install

import (
	"context"
	"fmt"

	"github.com/zoncaesaradmin/appliance-release/internal/bundle"
	"github.com/zoncaesaradmin/appliance-release/internal/evidence"
	"github.com/zoncaesaradmin/appliance-release/internal/images"
	"github.com/zoncaesaradmin/appliance-release/internal/verify"
)

// Resolved is every artifact the install sequence needs, as local
// filesystem paths, regardless of whether a Source acquired them from a
// verified offline bundle or fetched them from the network. This is what
// lets Install run one identical sequence for both online and offline
// installation — see docs/release-plan.md's Strategy Update.
type Resolved struct {
	ReleaseID     string
	Compatibility bundle.Compatibility

	K3sBinaryPath     string
	ChartPath         string
	CRDPath           string
	ConfigurationPath string

	// K3sImages and OCIImages are preloaded directly into the K3s image
	// store when non-empty (the offline path). A Source that doesn't
	// preload images (the online path, where K3s pulls images itself
	// over the network it already has) simply returns them empty.
	K3sImages []images.Image
	OCIImages []images.Image
}

// Source acquires and verifies every artifact Install needs, returning
// local paths. OfflineSource reads a signed local bundle; OnlineSource
// fetches from the network. Both fail closed on any missing artifact,
// digest mismatch, or bad signature.
type Source interface {
	Resolve(ctx context.Context) (Resolved, []evidence.Check, error)
}

// OfflineSource resolves artifacts from a verified local air-gap bundle.
type OfflineSource struct {
	BundleDir string
	PublicKey *verify.PublicKey
}

func (s OfflineSource) Resolve(ctx context.Context) (Resolved, []evidence.Check, error) {
	b, checks, err := bundle.Load(s.BundleDir, s.PublicKey)
	if err != nil {
		return Resolved{}, checks, fmt.Errorf("install: %w", err)
	}

	k3sBinaryPath, ok := b.Path("k3s-binary")
	if !ok {
		return Resolved{}, checks, fmt.Errorf("install: bundle has no k3s-binary entry")
	}
	chartPath, ok := b.Path("chart")
	if !ok {
		return Resolved{}, checks, fmt.Errorf("install: bundle has no chart entry")
	}
	crdPath, ok := b.Path("crds")
	if !ok {
		return Resolved{}, checks, fmt.Errorf("install: bundle has no crds entry")
	}
	configurationPath, ok := b.Path("configuration")
	if !ok {
		return Resolved{}, checks, fmt.Errorf("install: bundle has no configuration entry")
	}

	var k3sImages, ociImages []images.Image
	for _, e := range b.Entries("k3s-images") {
		k3sImages = append(k3sImages, images.Image{Name: imageName(e), ArchivePath: e.Path, ExpectedDigest: e.Digest, Category: images.CategoryK3sPlatform})
	}
	for _, e := range b.Entries("oci-images") {
		ociImages = append(ociImages, images.Image{Name: imageName(e), ArchivePath: e.Path, ExpectedDigest: e.Digest, Category: images.CategoryApplication})
	}

	return Resolved{
		ReleaseID:         b.ReleaseID,
		Compatibility:     b.Compatibility,
		K3sBinaryPath:     k3sBinaryPath,
		ChartPath:         chartPath,
		CRDPath:           crdPath,
		ConfigurationPath: configurationPath,
		K3sImages:         k3sImages,
		OCIImages:         ociImages,
	}, checks, nil
}

func imageName(e bundle.Entry) string {
	if e.ImageReference != "" {
		return e.ImageReference
	}
	return e.Path
}
