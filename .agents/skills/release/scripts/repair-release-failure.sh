#!/usr/bin/env bash
# Apply one narrowly-scoped, deterministic repair for a known packaging
# command-generation defect. The release loop commits/pushes separately after
# this script returns success; this script must never push or mutate remotes.
set -Eeuo pipefail

usage() {
  cat <<'EOF'
usage: repair-release-failure.sh --release-log PATH --repo-root PATH

Apply a safe local repair when the release log proves that the generated
archive-release-input command received an empty argument caused by early
POSTGIS_IMAGE_REF expansion.
EOF
}

die() {
  echo "repair-release-failure: $*" >&2
  exit 2
}

RELEASE_LOG=""
REPO_ROOT=""
while (($#)); do
  case "$1" in
    --release-log)
      (($# >= 2)) || die "$1 requires a path"
      RELEASE_LOG=$2
      shift 2
      ;;
    --repo-root)
      (($# >= 2)) || die "$1 requires a path"
      REPO_ROOT=$2
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ -f "$RELEASE_LOG" ]] || die "release log not found: $RELEASE_LOG"
[[ -d "$REPO_ROOT" ]] || die "repo root not found: $REPO_ROOT"

# Do not edit source for an unrelated failure. This signature is emitted by
# archive-release-input before its usage text and is paired with the exact
# malformed generator below.
if ! grep -Eqi 'archive-release-input: unknown argument:' "$RELEASE_LOG"; then
  exit 3
fi

TARGET="$REPO_ROOT/appliance-release/scripts/build-full-bundle.sh"
[[ -f "$TARGET" ]] || die "packaging generator not found: $TARGET"

python3 - "$TARGET" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
bad = r'''  POSTGIS_ARCHIVE_ARG_LINES+=$'\n  --extra-oci-image-reference "${POSTGIS_IMAGE_REF}" \\' '''.rstrip()
good = r'''  POSTGIS_ARCHIVE_ARG_LINES+=$'\n  --extra-oci-image-reference "\${POSTGIS_IMAGE_REF}" \\' '''.rstrip()

if good in text:
    print("repair-release-failure: POSTGIS archive reference expansion already repaired")
    raise SystemExit(3)
if bad not in text:
    print("repair-release-failure: no known POSTGIS archive expansion defect found", file=sys.stderr)
    raise SystemExit(3)

path.write_text(text.replace(bad, good, 1), encoding="utf-8")
print(f"repair-release-failure: repaired {path}")
PY
