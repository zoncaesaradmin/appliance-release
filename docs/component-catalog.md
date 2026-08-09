# Product component catalog (super-set packages)

This catalog is the stable contract for what lands in every complete product
`release-input` / signed air-gap super-bundle. It does **not** describe
install-time profile selection only. Host mDNS/Wi-Fi AP are day-2 Admin UI enablement.

Machine-readable list: [components.yaml](components.yaml).

The signed metadata bundle in this catalog is not limited to profiles. It is
also the delivery mechanism for dynamic appliance policy such as capabilities,
future MCP tool descriptors, and metadata-driven workflow definitions that the
installed software already knows how to execute.

## Package vs install

| Layer | Selects components? |
| --- | --- |
| `build-full-bundle` / release packaging | Always builds the full super-set below |
| `releasebundle.Assemble` | Copies whatever is in release-input (no profile filter) |
| `install.appliance_profile` | Modules activated on the target only |

## Component graph

```mermaid
flowchart TB
  subgraph product [appliance-code product path]
    cpImg[control-plane-image]
    uiImg[ui-image]
    haImg[host-agent-image]
    haBin[host-agent-binary]
    chart[control-plane-chart]
    schema[config-schema]
    artifactServerImg[artifact-server-image]
    artifactServerChart[registry-chart]
    dnsImg[coredns-image]
    dnsChart[dns-chart]
    workflowsChart[workflows-chart-crds]
    workflowsCtrl[workflow-controller-image]
    workflowsExec[workflow-executor-image]
    prov[workspace-provisioner]
    devBuild[dev-build]
    hostPkgs[host-packages]
    meta[metadata-bundle (policy + workflow defs)]
  end
  subgraph host [build-full-bundle assemble]
    k3s[k3s-binary + airgap-images]
    zonctl[zonctl + helpers]
    values[values + catalog]
    sign[sign full super-bundle]
  end
  product --> host
  host --> sign
```

## Stages (named build steps)

`scripts/build-full-bundle.sh` still runs **all** product stages in order for
a complete build. Named stage IDs match `components.yaml` `id` fields so Phase C
fingerprints can attach to the same units.

| Order | Stage / recipe | Primary outputs |
| --- | --- | --- |
| 1 | `clone-repos` | RELEASE_WORK_ROOT checkouts |
| 2 | `host-packages` | `.run/host-packages/ubuntu/<VER>/amd64/*.deb` (mdns + wifi-ap) |
| 3 | `artifact-server-image` / `dns-image` | first-class OCI archives + digest refs |
| 4 | `workflows-crds` / `workflow-controller` / `workflow-executor` | workflows engine offline set |
| 5 | `workspace-provisioner` + `dev-build` | bundled offline image archives |
| 6 | `product-images` | control-plane, UI, host-agent OCI + host-agentd |
| 7 | `archive-release-input` | release-input tar (super-set) |
| 8 | `assemble-and-sign` | **always** re-run → signed `appliance-*-foundation.tar.gz` |

Incremental rebuilds (Phase C) may skip stages 2–6 when fingerprints match;
stages 7–8 always re-run so the published artifact is one consistent release.

## Metadata Bundle Payload

The `metadata-bundle` component is a signed product-policy archive. Its payload
is expected to grow over time without changing the packaging layer away from a
single metadata artifact.

Today or planned next, that payload may include:

- `profiles/` for appliance profile catalogs
- `capabilities/` for capability dependencies, conflicts, and gating rules
- `activation/` for activation warnings and transition policy
- `ui/` for control-plane text and visibility metadata
- `notifications/` for operator-facing alerts and policy
- `mcp-tools/` for tool descriptors, policy, and MCP-style workflow-backed
  actions
- `debug-tools/` for debug-oriented workflow DSL files and their input/output
  schemas executed by the already-installed software runtime

This means dynamic workflow capability should ship through the signed metadata
bundle. Its Go-native Automation Runtime image and chart must ship in the
foundation independently of the developer workflows/Argo artifacts listed
above.

The release-side contract fixture for this metadata layout lives under
`docs/examples/metadata-bundle-contract/`.

## Developer slim path

`BUILD_COMPLETE_PRODUCT=false` (not used by the release skill) may omit the
workflows engine / dev-build for local fixtures. Production packaging defaults
`BUILD_COMPLETE_PRODUCT=true` and fails closed if the workflows engine or
`registry.local/dev-build` is missing.
