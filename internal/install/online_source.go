package install

import (
	"context"
	"encoding/json"
	"fmt"
	"path/filepath"
	"strings"
	"time"

	"github.com/zoncaesaradmin/appliance-release/internal/bundle"
	"github.com/zoncaesaradmin/appliance-release/internal/cli"
	"github.com/zoncaesaradmin/appliance-release/internal/evidence"
	"github.com/zoncaesaradmin/appliance-release/internal/fetch"
	"github.com/zoncaesaradmin/appliance-release/internal/manifest"
)

// LoadPlatformManifest fetches, schema-validates, and parses the
// platform manifest at url. The manifest document itself is fetched
// directly (its own digest can't be known in advance, unlike everything
// it then points at); schema validation is what keeps a malformed or
// unexpected manifest from ever reaching OnlineSource.Resolve.
func LoadPlatformManifest(ctx context.Context, get fetch.Getter, url string) (PlatformManifest, error) {
	data, err := get(ctx, url)
	if err != nil {
		return PlatformManifest{}, fmt.Errorf("install: fetch platform manifest: %w", err)
	}
	if err := manifest.Validate(manifest.KindPlatformManifest, data); err != nil {
		return PlatformManifest{}, fmt.Errorf("install: platform manifest at %s does not satisfy platform-manifest.v1: %w", url, err)
	}
	var m PlatformManifest
	if err := json.Unmarshal(data, &m); err != nil {
		return PlatformManifest{}, fmt.Errorf("install: parse platform manifest: %w", err)
	}
	return m, nil
}

// PlatformManifest is a Zon platform release, manifest-driven per
// docs/release-plan.md: PlatformVersion pins the supported K3s version
// and every chart/image version for one complete tested release, while
// Services carries each platform service's own independent version.
// zonctl reads this rather than hardcoding any of these values.
type PlatformManifest struct {
	PlatformVersion string `json:"platformVersion"`
	ReleaseID       string `json:"releaseId"`

	K3sVersion      string `json:"k3sVersion"`
	K3sBinaryURL    string `json:"k3sBinaryUrl"`
	K3sBinaryDigest string `json:"k3sBinaryDigest"` // "sha256:<hex>"

	// ChartRepository must be an OCI-based Helm registry reference (e.g.
	// "oci://registry.example.com/zon-platform"); `helm pull` resolves
	// ChartName/ChartVersion from it. Classic (non-OCI) chart repos are
	// not supported in v1 online mode.
	ChartRepository string `json:"chartRepository"`
	ChartName       string `json:"chartName"`
	ChartVersion    string `json:"chartVersion"`

	CRDsURL    string `json:"crdsUrl"`
	CRDsDigest string `json:"crdsDigest"`

	ConfigurationURL    string `json:"configurationUrl"`
	ConfigurationDigest string `json:"configurationDigest"`

	ArgoVersion             string   `json:"argoVersion"`
	SupportedUpgradeSources []string `json:"supportedUpgradeSources"`

	// Services maps each platform service (e.g. "zon-core", "zon-api",
	// "zon-ui", "zon-registry", "zon-observability", "zon-agent") to its
	// own version, independent of PlatformVersion. This is metadata for
	// status reporting and support bundles; the chart itself is what
	// actually deploys these services at their pinned versions.
	Services map[string]string `json:"services,omitempty"`
	// EnabledComponents lists which optional platform components this
	// release enables by default.
	EnabledComponents []string `json:"enabledComponents,omitempty"`
}

// OnlineSource resolves artifacts by fetching them over the network:
// K3s binary, CRDs, and default configuration via verified HTTPS
// download, and the platform chart via `helm pull` from an OCI registry.
// It never preloads images — unlike the offline path, K3s/containerd
// simply pulls images itself, since the network is already available.
type OnlineSource struct {
	Manifest PlatformManifest
	Get      fetch.Getter
	HelmRun  cli.Runner
	// WorkDir is a scratch directory OnlineSource downloads artifacts
	// into (e.g. <state-dir>/online-cache).
	WorkDir string
}

func (s OnlineSource) Resolve(ctx context.Context) (Resolved, []evidence.Check, error) {
	var checks []evidence.Check

	k3sBinaryPath := filepath.Join(s.WorkDir, "k3s")
	if err := fetch.DownloadVerified(ctx, s.Get, s.Manifest.K3sBinaryURL, s.Manifest.K3sBinaryDigest, k3sBinaryPath, 0o755); err != nil {
		checks = append(checks, failedCheck("fetch-k3s-binary", err))
		return Resolved{}, checks, fmt.Errorf("install: %w", err)
	}
	checks = append(checks, passedCheck("fetch-k3s-binary", "k3s binary fetched and verified from "+s.Manifest.K3sBinaryURL))

	crdPath := filepath.Join(s.WorkDir, "crds.yaml")
	if err := fetch.DownloadVerified(ctx, s.Get, s.Manifest.CRDsURL, s.Manifest.CRDsDigest, crdPath, 0o640); err != nil {
		checks = append(checks, failedCheck("fetch-crds", err))
		return Resolved{}, checks, fmt.Errorf("install: %w", err)
	}
	checks = append(checks, passedCheck("fetch-crds", "CRDs fetched and verified from "+s.Manifest.CRDsURL))

	configurationPath := filepath.Join(s.WorkDir, "values.yaml")
	if err := fetch.DownloadVerified(ctx, s.Get, s.Manifest.ConfigurationURL, s.Manifest.ConfigurationDigest, configurationPath, 0o640); err != nil {
		checks = append(checks, failedCheck("fetch-configuration", err))
		return Resolved{}, checks, fmt.Errorf("install: %w", err)
	}
	checks = append(checks, passedCheck("fetch-configuration", "default configuration fetched and verified from "+s.Manifest.ConfigurationURL))

	if !strings.HasPrefix(s.Manifest.ChartRepository, "oci://") {
		err := fmt.Errorf("install: chart repository %q must be an OCI registry reference (oci://...)", s.Manifest.ChartRepository)
		checks = append(checks, failedCheck("fetch-chart", err))
		return Resolved{}, checks, err
	}
	chartDestDir := filepath.Join(s.WorkDir, "chart")
	chartRef := strings.TrimSuffix(s.Manifest.ChartRepository, "/") + "/" + s.Manifest.ChartName
	if _, err := s.HelmRun(ctx, "helm", "pull", chartRef, "--version", s.Manifest.ChartVersion, "-d", chartDestDir); err != nil {
		wrapped := fmt.Errorf("install: pull chart %s: %w", chartRef, err)
		checks = append(checks, failedCheck("fetch-chart", wrapped))
		return Resolved{}, checks, wrapped
	}
	chartPath := filepath.Join(chartDestDir, fmt.Sprintf("%s-%s.tgz", s.Manifest.ChartName, s.Manifest.ChartVersion))
	checks = append(checks, passedCheck("fetch-chart", fmt.Sprintf("chart %s pulled from %s", s.Manifest.ChartVersion, chartRef)))

	return Resolved{
		ReleaseID: s.Manifest.ReleaseID,
		Compatibility: bundle.Compatibility{
			K3sVersion:              s.Manifest.K3sVersion,
			ChartVersion:            s.Manifest.ChartVersion,
			ArgoVersion:             s.Manifest.ArgoVersion,
			SupportedUpgradeSources: s.Manifest.SupportedUpgradeSources,
		},
		K3sBinaryPath:     k3sBinaryPath,
		ChartPath:         chartPath,
		CRDPath:           crdPath,
		ConfigurationPath: configurationPath,
		// K3sImages/OCIImages intentionally empty: no offline preload
		// step in online mode.
	}, checks, nil
}

func passedCheck(id, message string) evidence.Check {
	return evidence.Check{
		ID: id, Category: "manifest", Status: evidence.StatusPass,
		Message: message, Timestamp: time.Now().UTC(), Idempotent: true, SecretsRedacted: true,
	}
}

func failedCheck(id string, err error) evidence.Check {
	return evidence.Check{
		ID: id, Category: "manifest", Status: evidence.StatusFail,
		Message: err.Error(), Timestamp: time.Now().UTC(), Idempotent: true, SecretsRedacted: true,
	}
}
