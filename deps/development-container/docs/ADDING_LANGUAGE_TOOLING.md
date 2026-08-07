# Adding Language Tooling

The current combined dev image is intentionally limited to Go, Python, and OCI container tooling.

When you need another language later, use this pattern:

1. Add an installer script in `scripts/`.
   Example: `scripts/install-rust.sh`
2. Add a dedicated image definition in the repository root.
   Example: `Containerfile.rust`
3. Decide whether the language belongs only in its own image or also in the combined dev image.
4. If it should be available in the main dev container, add the installer to `Containerfile.dev`.
5. Add build targets to `Makefile`.

## What to change

- Shared/common packages:
  `scripts/install-common.sh`
- Go-specific tooling:
  `scripts/install-go.sh`
- Python-specific tooling:
  `scripts/install-python.sh`
- Combined dev container contents:
  `Containerfile.dev`
- Per-image build commands and tags:
  `Makefile`

## Rule of thumb

Keep `scripts/install-common.sh` limited to packages that are broadly useful across multiple languages or required for container/image building.

Put language runtimes, package managers, and language-specific developer tools in their own installer scripts so the combined image only grows when there is a concrete need.
