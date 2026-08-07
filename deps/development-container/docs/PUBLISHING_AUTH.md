# Publishing Authentication (`DEV_REGISTRY_USER` / `DEV_REGISTRY_TOKEN`)

The `make login`, `make publish`, and `make release` targets (see [Makefile](../Makefile) and the "Publishing images to a registry" section of the [README](../README.md)) authenticate to the configured `DEV_REGISTRY` using two environment variables:

- `DEV_REGISTRY_USER`
- `DEV_REGISTRY_TOKEN`

These are never hardcoded or committed to the repo — they must always be supplied via the environment (or CI secrets). What to set them to depends on who/what is publishing.

For a LAN / internal OCI registry, use the same `login` / `publish` / `release` targets with `DEV_REGISTRY=<lan-host>`, `DEV_IMAGE_REPO=development-container`, and that registry's `DEV_REGISTRY_USER` / `DEV_REGISTRY_TOKEN`. Token format depends on the registry (appliance API token, htpasswd, etc.), not GitHub PAT scopes.


## Individual GitHub user (manual/local publish)

- **`DEV_REGISTRY_USER`** — your GitHub **username** (e.g. `zoncaesaradmin`). Not your email, not your display name.
- **`DEV_REGISTRY_TOKEN`** — a GitHub **Personal Access Token (classic)** with the `write:packages` scope (this also grants `read:packages`). Do not use your account password.

### Creating the token

1. github.com → your avatar → **Settings** → **Developer settings** → **Personal access tokens** → **Tokens (classic)** → **Generate new token**.
2. Select scope: `write:packages`.
3. Set an expiration date — rotate regularly rather than choosing "no expiration" for a credential you'll reuse.
4. Copy the token immediately; GitHub only shows it once.

### Using it

```bash
export DEV_REGISTRY=ghcr.io
export DEV_REGISTRY_USER=zoncaesaradmin
export DEV_IMAGE_REPO=$DEV_REGISTRY_USER/development-container
export DEV_REGISTRY_TOKEN=ghp_xxxxxxxxxxxxxxxxxxxx
make login
```

Each person publishing manually uses **their own username and their own PAT**. There is no shared/bot account needed for this path — GHCR push permission follows normal GitHub org/repo collaborator access, so each individual token is authorized (or not) the same way their GitHub account already is.

Treat the token like a password:
- Never commit it to a file in this repo.
- Never put it directly in shell history in a way that gets shared (prefer an env file outside the repo, a secrets manager, or typing it interactively).
- Revoke it immediately from GitHub settings if it leaks.

## CI (GitHub Actions)

CI does not need a manually created PAT for the common case — GitHub Actions provides a built-in, short-lived, repo-scoped token automatically.

- **`DEV_REGISTRY_USER`** → `${{ github.actor }}` (the user/bot that triggered the run). A fixed placeholder string also works since GHCR only cares that the token is valid.
- **`DEV_REGISTRY_TOKEN`** → `${{ secrets.GITHUB_TOKEN }}`, injected automatically into every workflow run. Requires the job to declare `permissions: packages: write`.

Example workflow:

```yaml
name: Publish development-container/dev-build image

on:
  push:
    branches: [main]

jobs:
  publish:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    env:
      DEV_REGISTRY: ghcr.io
      DEV_IMAGE_REPO: ${{ github.actor }}/development-container
      DEV_REGISTRY_USER: ${{ github.actor }}
      DEV_REGISTRY_TOKEN: ${{ secrets.GITHUB_TOKEN }}
    steps:
      - uses: actions/checkout@v4
      - name: Install buildah
        run: sudo apt-get update && sudo apt-get install -y buildah
      - run: make login
      - run: make build-dev
      - run: make test-dev
      - run: make VERSION=${{ github.sha }} publish
```

Why this is preferred over a PAT in CI:
- `GITHUB_TOKEN` is automatically scoped to the current repo/org and expires when the job finishes — nothing to create, store, or rotate.
- It cannot be used to push anywhere outside the workflow's own repo, which limits blast radius if a workflow is ever compromised.

### When CI does need a real PAT

Only if the image must be published to a package under a **different** repo or org than the one running the workflow — `GITHUB_TOKEN` can't reach outside its own repo/org. In that case:

1. Create a PAT the same way as the individual-user flow above (ideally on a dedicated bot/service account, not a personal account, so it isn't tied to one person leaving or rotating their own credentials).
2. Store it as a **repository or organization secret**: `Settings → Secrets and variables → Actions → New repository secret` (e.g. named `GHCR_PUBLISH_TOKEN`).
3. Reference it in the workflow as `secrets.GHCR_PUBLISH_TOKEN` — never paste the raw value into the workflow YAML.

## Future registry migration

Changing destination is only env values (`DEV_REGISTRY`, `DEV_IMAGE_REPO`, `DEV_IMAGE_NAME`, credentials). Same `login` / `publish` / `release` targets. The `DEV_REGISTRY_USER` / `DEV_REGISTRY_TOKEN` contract stays the same shape (GitHub PAT vs LAN registry token).
