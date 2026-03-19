#!/usr/bin/env bash
# Run only base-path proxy compatibility checks with managed server lifecycle.

set -ex

# Ensure current path is project root
cd "$(dirname "$0")/../"

QDRANT_HOST=${QDRANT_HOST:-"127.0.0.1:63330"}

if command -v curl.exe >/dev/null 2>&1; then
  CURL_BIN="curl.exe"
else
  CURL_BIN="curl"
fi

if [ -n "${QDRANT_EXECUTABLE:-}" ]; then
  QDRANT_BIN="$QDRANT_EXECUTABLE"
elif [ -f "./target/debug/qdrant" ]; then
  QDRANT_BIN="./target/debug/qdrant"
else
  QDRANT_BIN="./target/debug/qdrant.exe"
fi

TMP_DIR="./target/base-path-proxy-test-${RANDOM:-0}-$$"
STATIC_DIR="$TMP_DIR/static"
STORAGE_DIR="$TMP_DIR/storage"
SNAPSHOTS_DIR="$TMP_DIR/snapshots"

mkdir -p "$STATIC_DIR" "$STORAGE_DIR" "$SNAPSHOTS_DIR"

cat > "$STATIC_DIR/index.html" <<'HTML'
<!doctype html>
<html>
  <head><meta charset="utf-8"><title>Qdrant Test UI</title></head>
  <body>Proxy Subpath UI Test</body>
</html>
HTML

# Minimal valid icon payload for static check
printf "ICO" > "$STATIC_DIR/favicon.ico"

cat > "$TMP_DIR/config.yaml" <<YAML
service:
  http_port: 63330
  grpc_port: 63331
  base_path: /qdrant
  static_content_dir: "$STATIC_DIR"
storage:
  storage_path: "$STORAGE_DIR"
  snapshots_path: "$SNAPSHOTS_DIR"
YAML

"$QDRANT_BIN" --config-path "$TMP_DIR/config.yaml" &
PID=$!

function clear_after_tests()
{
  echo "server is going down"
  kill -9 "$PID" || true
  rm -rf "$TMP_DIR" || true
  echo "END"
}

trap clear_after_tests SIGINT
trap clear_after_tests EXIT

BASE_URL="http://$QDRANT_HOST"
MAX_RETRIES=${MAX_RETRIES:-60}
retry=0

until [ "$retry" -ge "$MAX_RETRIES" ]; do
  status_code=$($CURL_BIN --noproxy "*" --output /dev/null --silent --get --write-out "%{http_code}" "$BASE_URL/collections" || true)

  if [ "$status_code" = "200" ]; then
    break
  fi

  retry=$((retry + 1))
  printf 'waiting for server to start... (%s/%s, /collections -> %s)\n' "$retry" "$MAX_RETRIES" "$status_code"
  sleep 5
done

if [ "$status_code" != "200" ]; then
  echo "ERROR: qdrant did not become ready at $BASE_URL/collections after $MAX_RETRIES retries"
  exit 1
fi

echo "server ready to serve traffic"

./tests/base_path_proxy_compat_test.sh
