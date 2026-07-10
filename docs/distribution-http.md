# HTTP Distribution

This is the current recommended simple distribution model for the files
exported by `scripts/ci/build-full-bundle.sh`.

The idea is:

1. Build the release bundle on the CI/build machine.
2. Export:
   - `appliance-<version>-bundle.tar.gz`
   - `release-signing.pub`
3. Copy those files to a separate download server over SSH/SCP.
4. Serve them from that server over HTTP or HTTPS.
5. The customer downloads them locally and then installs from local disk.

This keeps distribution separate from build, and keeps install itself
offline.

The extracted bundle now carries its own `zonctl` launcher plus bundle-local
`helm`, `kubectl`, and `ctr` helpers, so the target host does not need those
tools installed separately.

## Recommendation

For a temporary setup, the simplest distribution server is just a plain file
directory served over Python's built-in HTTP server.

For a longer-lived internal setup, use NGINX.

- Keep the build machine responsible only for producing files.
- Keep the distribution machine responsible only for storing and serving files.
- Prefer HTTPS in real environments, even on a LAN.
- Use immutable versioned paths.
- Optionally also publish a `latest/` alias for convenience.

Example versioned paths:

- `/releases/appliance/0.1.0/appliance-0.1.0-bundle.tar.gz`
- `/releases/appliance/0.1.0/release-signing.pub`
- `/releases/appliance/0.1.0/sha256sum.txt`

## Temporary Server Setup

On the distribution server:

```bash
mkdir -p ~/releases
cd ~/releases
python3 -m http.server 8080
```

If port `8080` is already in use, pick another port such as `8081`.

This is enough for short-lived LAN testing once the published files exist under
that directory tree.

If you publish to:

- `PUBLISH_REMOTE_ROOT=/home/zonsys/releases`

then the matching temporary fetch/install base URL is:

- `http://<server>:8080`

## Longer-Lived Server Setup

On the distribution server:

```bash
sudo apt update
sudo apt install -y nginx
sudo mkdir -p /srv/www/releases/appliance
sudo chown -R "$USER":"$USER" /srv/www/releases
```

Create an NGINX site config:

```nginx
server {
    listen 80;
    server_name downloads.example.internal;

    root /srv/www;
    autoindex on;

    location /releases/ {
        try_files $uri $uri/ =404;
    }
}
```

Save it, for example, as `/etc/nginx/sites-available/appliance-releases`,
then enable it:

```bash
sudo ln -sf /etc/nginx/sites-available/appliance-releases /etc/nginx/sites-enabled/appliance-releases
sudo nginx -t
sudo systemctl reload nginx
```

After that, files copied under `/srv/www/releases/...` are available over
HTTP from:

```text
http://downloads.example.internal/releases/...
```

For a real setup, put HTTPS and your chosen auth mechanism in front of
this later.

## Publish From The Build Machine

After `build-full-bundle.sh` finishes, publish the exported files:

Temporary Python-server style:

```bash
export PRODUCT_VERSION=0.1.0
make publish-release \
  EXPORT_DIR=/home/zonsys/appliance-build/export \
  PUBLISH_SERVER=zonsys@192.168.1.103 \
  PUBLISH_REMOTE_ROOT=/home/zonsys/releases
```

Without `PUBLISH_PUBLIC_BASE_URL`, the script now auto-derives:

```text
http://192.168.1.103
```

from `PUBLISH_SERVER=zonsys@192.168.1.103` and prints commands using that base
URL. If your HTTP server uses a non-default port such as `28081`, or serves
from an extra base path, set `PUBLISH_PUBLIC_BASE_URL` explicitly.

Longer-lived NGINX-style:

```bash
export PRODUCT_VERSION=0.1.0
make publish-release \
  EXPORT_DIR=/home/zonsys/appliance-build/export \
  PUBLISH_SERVER=release@downloads.example.internal \
  PUBLISH_REMOTE_ROOT=/srv/www/releases \
  PUBLISH_PUBLIC_BASE_URL=http://downloads.example.internal/releases
```

Mandatory variables for `make publish-release`:

- `EXPORT_DIR`
  This is where `build-full-bundle.sh` left the local exported files.
- `PRODUCT_VERSION`
  Used to pick `appliance-<version>-bundle.tar.gz` and create the remote version path.
  It can be passed inline or already exported in the shell.
- `PUBLISH_SERVER`
  The SSH target in `user@host` form.
- `PUBLISH_REMOTE_ROOT`
  The remote filesystem root where the published files should be copied.

Optional variables:

- `PUBLISH_PUBLIC_BASE_URL`
  Optional override for the public HTTP/HTTPS base URL. If omitted, the script
  derives `http://<host>` from `PUBLISH_SERVER` and prints commands using that
  derived value.
- `PUBLISH_LATEST_ALIAS=1`
  Also copies the same files under `latest/`.
- `PUBLISH_PATH_PREFIX`
  Defaults to `appliance`.
- `PUBLISH_SSH_PORT`
  Defaults to `22`.

`make publish-release` prints the exact target-host commands for:

- install
- latest alias install, if `PUBLISH_LATEST_ALIAS=1` is enabled

If the derived base URL is not the real public URL, rerun with
`PUBLISH_PUBLIC_BASE_URL=...`.

That command:

- creates a versioned directory on the remote server
- copies:
  - `appliance-0.1.0-bundle.tar.gz`
  - `release-signing.pub`
  - `sha256sum.txt`
  - `install-http-release.sh`
- optionally updates `latest/`

Equivalent direct script invocation:

```bash
bash ./scripts/publish/publish-release.sh \
  --export-dir /home/zonsys/appliance-build/export \
  --product-version 0.1.0 \
  --server release@downloads.example.internal \
  --remote-root /srv/www/releases
```

## What The Target Host Runs

The target host does not need this repo.

Temporary Python-server style:

```bash
curl -fLo /tmp/install-http-release.sh \
  http://192.168.1.103:8080/appliance/0.1.0/install-http-release.sh
bash /tmp/install-http-release.sh \
  --base-url http://192.168.1.103:8080
```

Longer-lived NGINX-style:

```bash
curl -fLo /tmp/install-http-release.sh \
  http://downloads.example.internal/releases/appliance/0.1.0/install-http-release.sh
bash /tmp/install-http-release.sh \
  --base-url http://downloads.example.internal/releases
```

The normal customer install entrypoint is the single piped command:

```bash
curl -fsSL http://192.168.1.103:28081/appliance/0.1.0/install-http-release.sh \
  | bash -s -- --base-url http://192.168.1.103:28081
```

That one command downloads the release, verifies checksums, extracts the
bundle, runs `zonctl preflight`, runs `zonctl install`, and prompts for the
first administrator password during install.

The install helper downloads:

- `appliance-0.1.0-bundle.tar.gz`
- `release-signing.pub`
- `sha256sum.txt`

The install helper verifies checksums, extracts locally, then runs:

- `zonctl preflight`
- `zonctl install`

Those install-time `zonctl` commands use the bundle-local helper binaries, not
host-installed `helm` or `kubectl`. `zonctl install` now also handles
first-admin bootstrap in the same flow: for a human operator it prompts on the
terminal for the initial administrator password instead of requiring a separate
pod-level bootstrap command.

If you published a `latest/` alias, the same install helper can use that too:

```bash
curl -fLo /tmp/install-http-release.sh \
  http://downloads.example.internal/releases/appliance/latest/install-http-release.sh
bash /tmp/install-http-release.sh \
  --base-url http://downloads.example.internal/releases \
  --use-latest
```

The published helper name is stable. The product version is carried inside
the script content and the versioned release path in the URL.

No extra host package install is required for Helm, kubectl, or ctr in that
flow. They are resolved from inside the extracted bundle.

After a successful install, the installer also places `zonctl` on the target
host at `/usr/local/bin/zonctl`, so day-2 commands can be run directly:

```bash
sudo zonctl status --output json
sudo zonctl verify --output json
sudo zonctl support-bundle --output json
```

## Why This Is Separate From The Build Script

The build script should always produce the release files in a predictable
local export directory.

Publishing is a separate concern because it can vary by environment:

- simple HTTP server
- object storage
- Artifactory
- OCI registry such as zot

Keeping publishing separate lets us add future modes without making the
bundle build itself environment-specific.
