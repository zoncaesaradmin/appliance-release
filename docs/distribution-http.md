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
make publish-release \
  EXPORT_DIR=/home/zonsys/appliance-build/export \
  PRODUCT_VERSION=0.1.0 \
  PUBLISH_SERVER=zonsys@192.168.1.103 \
  PUBLISH_REMOTE_ROOT=/home/zonsys/releases
```

Longer-lived NGINX-style:

```bash
make publish-release \
  EXPORT_DIR=/home/zonsys/appliance-build/export \
  PRODUCT_VERSION=0.1.0 \
  PUBLISH_SERVER=release@downloads.example.internal \
  PUBLISH_REMOTE_ROOT=/srv/www/releases
```

Mandatory variables for `make publish-release`:

- `EXPORT_DIR`
  This is where `build-full-bundle.sh` left the local exported files.
- `PRODUCT_VERSION`
  Used to pick `appliance-<version>-bundle.tar.gz` and create the remote version path.
- `PUBLISH_SERVER`
  The SSH target in `user@host` form.
- `PUBLISH_REMOTE_ROOT`
  The remote filesystem root where the published files should be copied.

Optional variables:

- `PUBLISH_PUBLIC_BASE_URL`
  If set, the script prints final download URLs.
- `PUBLISH_LATEST_ALIAS=1`
  Also copies the same files under `latest/`.
- `PUBLISH_PATH_PREFIX`
  Defaults to `appliance`.
- `PUBLISH_SSH_PORT`
  Defaults to `22`.

That command:

- creates a versioned directory on the remote server
- copies:
  - `appliance-0.1.0-bundle.tar.gz`
  - `release-signing.pub`
  - `sha256sum.txt`
  - `fetch-http-release.sh`
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
  --base-url http://192.168.1.103:8080 \
  --product-version 0.1.0
```

Longer-lived NGINX-style:

```bash
curl -fLo /tmp/install-http-release.sh \
  http://downloads.example.internal/releases/appliance/0.1.0/install-http-release.sh
bash /tmp/install-http-release.sh \
  --base-url http://downloads.example.internal/releases \
  --product-version 0.1.0
```

If you only want to download and extract without installing yet:

```bash
curl -fLo /tmp/fetch-http-release.sh \
  http://downloads.example.internal/releases/appliance/0.1.0/fetch-http-release.sh
bash /tmp/fetch-http-release.sh \
  --base-url http://downloads.example.internal/releases \
  --product-version 0.1.0 \
  --out-dir /tmp/appliance-0.1.0
```

Those helper scripts download:

- `appliance-0.1.0-bundle.tar.gz`
- `release-signing.pub`
- `sha256sum.txt`

The fetch helper verifies checksums and extracts locally.

The install helper does the same, then runs:

- `zonctl preflight`
- `zonctl install`

If you published a `latest/` alias, the fetch side can use that too:

```bash
curl -fLo /tmp/install-http-release.sh \
  http://downloads.example.internal/releases/appliance/latest/install-http-release.sh
bash /tmp/install-http-release.sh \
  --base-url http://downloads.example.internal/releases \
  --product-version 0.1.0 \
  --use-latest
```

If you used only the fetch helper, then install from the extracted local directory:

```bash
chmod +x /tmp/appliance-0.1.0/appliance-0.1.0-bundle/zonctl
sudo /tmp/appliance-0.1.0/appliance-0.1.0-bundle/zonctl preflight --output json
sudo /tmp/appliance-0.1.0/appliance-0.1.0-bundle/zonctl install \
  --bundle-dir /tmp/appliance-0.1.0/appliance-0.1.0-bundle \
  --public-key /tmp/appliance-0.1.0/release-signing.pub \
  --state-dir /var/lib/zon \
  --output json
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
