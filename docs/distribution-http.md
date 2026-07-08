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

Use a small NGINX server on the distribution machine.

- Keep the build machine responsible only for producing files.
- Keep the distribution machine responsible only for storing and serving files.
- Prefer HTTPS in real environments, even on a LAN.
- Use immutable versioned paths.
- Optionally also publish a `latest/` alias for convenience.

Example versioned paths:

- `/releases/appliance/0.1.0/appliance-0.1.0-bundle.tar.gz`
- `/releases/appliance/0.1.0/release-signing.pub`
- `/releases/appliance/0.1.0/sha256sum.txt`

## Server Setup

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

```bash
make publish-release \
  PUBLISH_MODE=http-static \
  EXPORT_DIR=/home/zonsys/appliance-build/export \
  PRODUCT_VERSION=0.1.0 \
  PUBLISH_SERVER=release@downloads.example.internal \
  PUBLISH_REMOTE_ROOT=/srv/www/releases \
  PUBLISH_PUBLIC_BASE_URL=http://downloads.example.internal/releases \
  PUBLISH_LATEST_ALIAS=1
```

That command:

- creates a versioned directory on the remote server
- copies:
  - `appliance-0.1.0-bundle.tar.gz`
  - `release-signing.pub`
  - `sha256sum.txt`
- optionally updates `latest/`

Equivalent direct script invocation:

```bash
bash ./scripts/publish/publish-release.sh \
  --mode http-static \
  --export-dir /home/zonsys/appliance-build/export \
  --product-version 0.1.0 \
  --server release@downloads.example.internal \
  --remote-root /srv/www/releases \
  --public-base-url http://downloads.example.internal/releases \
  --latest-alias
```

## What The Customer Runs

The simplest path is now the fetch helper in this repo:

```bash
make fetch-http-release \
  FETCH_BASE_URL=http://downloads.example.internal/releases \
  PRODUCT_VERSION=0.1.0 \
  FETCH_OUT_DIR=/tmp/appliance-0.1.0
```

Equivalent direct script invocation:

```bash
bash ./scripts/publish/fetch-http-release.sh \
  --base-url http://downloads.example.internal/releases \
  --product-version 0.1.0 \
  --out-dir /tmp/appliance-0.1.0
```

That command downloads:

- `appliance-0.1.0-bundle.tar.gz`
- `release-signing.pub`
- `sha256sum.txt`

then verifies the checksums and extracts the bundle locally.

If you published a `latest/` alias, the fetch side can use that too:

```bash
make fetch-http-release \
  FETCH_BASE_URL=http://downloads.example.internal/releases \
  PRODUCT_VERSION=0.1.0 \
  FETCH_OUT_DIR=/tmp/appliance-0.1.0 \
  FETCH_USE_LATEST=1
```

Then install from the extracted local directory:

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
