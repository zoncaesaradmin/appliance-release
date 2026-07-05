package install_test

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/zoncaesaradmin/appliance-release/internal/install"
)

func digestOf(content string) string {
	sum := sha256.Sum256([]byte(content))
	return "sha256:" + hex.EncodeToString(sum[:])
}

// fakeContent maps a URL to the bytes a fake Getter should return for it.
type fakeContent map[string]string

func (c fakeContent) get(_ context.Context, url string) ([]byte, error) {
	content, ok := c[url]
	if !ok {
		return nil, errors.New("unexpected URL: " + url)
	}
	return []byte(content), nil
}

func sampleManifest() install.PlatformManifest {
	return install.PlatformManifest{
		PlatformVersion:     "2.4.0",
		ReleaseID:           "release-2.4.0",
		K3sVersion:          "v1.30.4+k3s1",
		K3sBinaryURL:        "https://example.invalid/k3s",
		K3sBinaryDigest:     digestOf("k3s binary bytes"),
		ChartRepository:     "oci://registry.example.invalid/zon-platform",
		ChartName:           "zon",
		ChartVersion:        "2.4.0",
		CRDsURL:             "https://example.invalid/crds.yaml",
		CRDsDigest:          digestOf("crd manifest bytes"),
		ConfigurationURL:    "https://example.invalid/values.yaml",
		ConfigurationDigest: digestOf("replicaCount: 1\n"),
		ArgoVersion:         "3.5.2",
	}
}

func TestOnlineSource_Resolve_Success(t *testing.T) {
	manifest := sampleManifest()
	content := fakeContent{
		manifest.K3sBinaryURL:     "k3s binary bytes",
		manifest.CRDsURL:          "crd manifest bytes",
		manifest.ConfigurationURL: "replicaCount: 1\n",
	}

	var helmCalls []string
	helmRun := func(_ context.Context, name string, args ...string) (string, error) {
		helmCalls = append(helmCalls, name+" "+strings.Join(args, " "))
		// Simulate `helm pull` writing the chart tarball into -d <dir>.
		var destDir string
		for i, a := range args {
			if a == "-d" && i+1 < len(args) {
				destDir = args[i+1]
			}
		}
		if destDir == "" {
			return "", errors.New("no -d destination given")
		}
		if err := os.MkdirAll(destDir, 0o750); err != nil {
			return "", err
		}
		chartFile := filepath.Join(destDir, manifest.ChartName+"-"+manifest.ChartVersion+".tgz")
		return "", os.WriteFile(chartFile, []byte("fake chart bytes"), 0o640)
	}

	source := install.OnlineSource{
		Manifest: manifest,
		Get:      content.get,
		HelmRun:  helmRun,
		WorkDir:  t.TempDir(),
	}

	resolved, checks, err := source.Resolve(context.Background())
	if err != nil {
		t.Fatalf("expected Resolve to succeed, got: %v", err)
	}
	if len(checks) == 0 {
		t.Error("expected evidence checks")
	}
	if resolved.Compatibility.K3sVersion != manifest.K3sVersion {
		t.Errorf("expected K3sVersion %s, got %s", manifest.K3sVersion, resolved.Compatibility.K3sVersion)
	}
	if len(resolved.K3sImages) != 0 || len(resolved.OCIImages) != 0 {
		t.Error("expected no preloaded images for online mode")
	}

	for _, p := range []string{resolved.K3sBinaryPath, resolved.ChartPath, resolved.CRDPath, resolved.ConfigurationPath} {
		if _, err := os.Stat(p); err != nil {
			t.Errorf("expected resolved path %s to exist: %v", p, err)
		}
	}
	if len(helmCalls) != 1 || !strings.Contains(helmCalls[0], "pull") {
		t.Errorf("expected exactly one `helm pull` invocation, got %v", helmCalls)
	}
}

// Tamper: a K3s binary whose downloaded bytes don't match the pinned
// digest must fail closed before any chart/CRD fetch is attempted.
func TestOnlineSource_Resolve_DigestMismatchFailsClosed(t *testing.T) {
	manifest := sampleManifest()
	content := fakeContent{
		manifest.K3sBinaryURL: "tampered bytes, not what was pinned",
	}

	helmCalled := false
	helmRun := func(context.Context, string, ...string) (string, error) {
		helmCalled = true
		return "", nil
	}

	source := install.OnlineSource{Manifest: manifest, Get: content.get, HelmRun: helmRun, WorkDir: t.TempDir()}

	if _, _, err := source.Resolve(context.Background()); err == nil {
		t.Fatal("expected a K3s binary digest mismatch to fail")
	}
	if helmCalled {
		t.Error("expected no chart pull after the K3s binary failed verification")
	}
}

// Missing evidence: the chart repository must be an OCI reference; a
// non-OCI repository is refused before any helm invocation.
func TestOnlineSource_Resolve_RejectsNonOCIChartRepository(t *testing.T) {
	manifest := sampleManifest()
	manifest.ChartRepository = "https://charts.example.invalid/zon"
	content := fakeContent{
		manifest.K3sBinaryURL:     "k3s binary bytes",
		manifest.CRDsURL:          "crd manifest bytes",
		manifest.ConfigurationURL: "replicaCount: 1\n",
	}

	helmCalled := false
	helmRun := func(context.Context, string, ...string) (string, error) {
		helmCalled = true
		return "", nil
	}

	source := install.OnlineSource{Manifest: manifest, Get: content.get, HelmRun: helmRun, WorkDir: t.TempDir()}
	if _, _, err := source.Resolve(context.Background()); err == nil {
		t.Fatal("expected a non-OCI chart repository to be refused")
	}
	if helmCalled {
		t.Error("expected no helm invocation for a non-OCI repository")
	}
}

func TestLoadPlatformManifest_ParsesJSON(t *testing.T) {
	body := `{
		"schemaVersion": 1,
		"platformVersion": "2.4.0",
		"releaseId": "release-2.4.0",
		"k3sVersion": "v1.30.4+k3s1",
		"k3sBinaryUrl": "https://example.invalid/k3s",
		"k3sBinaryDigest": "` + digestOf("k3s-binary") + `",
		"chartRepository": "oci://registry.example.invalid/zon-platform",
		"chartName": "zon",
		"chartVersion": "2.4.0",
		"crdsUrl": "https://example.invalid/crds.yaml",
		"crdsDigest": "` + digestOf("crds") + `",
		"configurationUrl": "https://example.invalid/values.yaml",
		"configurationDigest": "` + digestOf("configuration") + `",
		"argoVersion": "3.5.2",
		"supportedUpgradeSources": ["2.3.0"],
		"services": {"zon-core": "2.4.0", "zon-api": "1.9.2"},
		"enabledComponents": ["zon-core", "zon-api"]
	}`
	get := func(context.Context, string) ([]byte, error) { return []byte(body), nil }

	m, err := install.LoadPlatformManifest(context.Background(), get, "https://example.invalid/manifest.json")
	if err != nil {
		t.Fatal(err)
	}
	if m.PlatformVersion != "2.4.0" || m.ChartName != "zon" || len(m.SupportedUpgradeSources) != 1 {
		t.Errorf("unexpected parsed manifest: %+v", m)
	}
	if m.Services["zon-core"] != "2.4.0" || m.Services["zon-api"] != "1.9.2" {
		t.Errorf("expected per-service versions to survive parsing, got %+v", m.Services)
	}
	if len(m.EnabledComponents) != 2 {
		t.Errorf("expected 2 enabled components, got %+v", m.EnabledComponents)
	}
}

// Missing evidence / schema violation: a manifest missing required
// fields (here, schemaVersion) must be rejected before it ever reaches
// OnlineSource.Resolve.
func TestLoadPlatformManifest_RejectsSchemaInvalidManifest(t *testing.T) {
	body := `{"platformVersion": "2.4.0"}` // missing schemaVersion and everything else required
	get := func(context.Context, string) ([]byte, error) { return []byte(body), nil }

	if _, err := install.LoadPlatformManifest(context.Background(), get, "https://example.invalid/manifest.json"); err == nil {
		t.Error("expected a schema-invalid platform manifest to be rejected")
	}
}

// Tamper: a chart repository that isn't an OCI reference is rejected by
// the schema itself, before OnlineSource ever runs.
func TestLoadPlatformManifest_RejectsNonOCIChartRepository(t *testing.T) {
	manifest := sampleManifest()
	manifest.ChartRepository = "https://charts.example.invalid/zon"
	body, err := json.Marshal(struct {
		SchemaVersion int `json:"schemaVersion"`
		install.PlatformManifest
	}{1, manifest})
	if err != nil {
		t.Fatal(err)
	}
	get := func(context.Context, string) ([]byte, error) { return body, nil }

	if _, err := install.LoadPlatformManifest(context.Background(), get, "https://example.invalid/manifest.json"); err == nil {
		t.Error("expected a non-OCI chart repository to be rejected by the schema")
	}
}
