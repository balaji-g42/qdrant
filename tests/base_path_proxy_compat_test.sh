#!/usr/bin/env bash
# Validate proxy subpath compatibility for API + Web UI mounts.

set -ex

QDRANT_HOST=${QDRANT_HOST:-"127.0.0.1:63330"}
TMP_DIR=${TMP_DIR:-"./target/base-path-proxy-test-artifacts"}
mkdir -p "$TMP_DIR"

if command -v curl.exe >/dev/null 2>&1; then
  CURL_BIN="curl.exe"
  NULL_DEVICE="NUL"
else
  CURL_BIN="curl"
  NULL_DEVICE="/dev/null"
fi

# API: root and base-path alias should both work
$CURL_BIN --noproxy "*" --fail -s "http://$QDRANT_HOST/collections" | jq
$CURL_BIN --noproxy "*" --fail -s "http://$QDRANT_HOST/qdrant/collections" | jq

# UI mount availability
$CURL_BIN --noproxy "*" --fail -s "http://$QDRANT_HOST/dashboard" > "$TMP_DIR/dashboard-root.html"
$CURL_BIN --noproxy "*" --fail -s "http://$QDRANT_HOST/qdrant/dashboard" > "$TMP_DIR/dashboard-base.html"

# Wrapper injection should exist on base-path mount HTML
grep -q "window.fetch" "$TMP_DIR/dashboard-base.html"
grep -q "XMLHttpRequest.prototype.open" "$TMP_DIR/dashboard-base.html"
grep -q "const BASE_PATH = \"/qdrant\";" "$TMP_DIR/dashboard-base.html"

# Static assets should be available on both mounts
root_favicon_code=$(
  $CURL_BIN --noproxy "*" -s -o "$NULL_DEVICE" -w "%{http_code}" "http://$QDRANT_HOST/dashboard/favicon.ico"
)
base_favicon_code=$(
  $CURL_BIN --noproxy "*" -s -o "$NULL_DEVICE" -w "%{http_code}" "http://$QDRANT_HOST/qdrant/dashboard/favicon.ico"
)

test "$root_favicon_code" = "200"
test "$base_favicon_code" = "200"
