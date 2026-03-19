#!/usr/bin/env bash
# This runs all integration test in isolation

set -ex

# Ensure current path is project root
cd "$(dirname "$0")/../"

MODE=$1
QDRANT_HOST="${QDRANT_HOST:-127.0.0.1:6333}"
QDRANT_BASE_PATH="${QDRANT_BASE_PATH:-}"
if [ -n "$QDRANT_BASE_PATH" ]; then
  # Normalize base path to either empty string (root) or '/prefix' (single leading slash, no trailing slash)
  QDRANT_BASE_PATH="$(printf '%s' "$QDRANT_BASE_PATH" | sed -E 's#^/+##; s#/+$##')"
fi

if [ -n "$QDRANT_BASE_PATH" ]; then
  QDRANT_BASE_PATH="/$QDRANT_BASE_PATH"
  export QDRANT_BASE_PATH
  export QDRANT__SERVICE__BASE_PATH="$QDRANT_BASE_PATH"
else
  QDRANT_BASE_PATH=""
  export QDRANT_BASE_PATH
  # Force root base path explicitly for integration tests to avoid
  # inheriting non-root base path from local config files.
  export QDRANT__SERVICE__BASE_PATH="/"
fi
BASE_URL="http://$QDRANT_HOST$QDRANT_BASE_PATH"
export QDRANT_HOST
export QDRANT__SERVICE__GRPC_PORT="6334"
export LLVM_PROFILE_FILE="./target/llvm-cov-target/qdrant-openapi-$MODE-%m.profraw"

# On Windows, prefer curl.exe so loopback checks behave consistently with cmd/PowerShell.
if command -v curl.exe >/dev/null 2>&1; then
  CURL_BIN="curl.exe"
else
  CURL_BIN="curl"
fi

if [ "$COVERAGE" == "1" ]; then
  QDRANT_EXECUTABLE="./target/llvm-cov-target/debug/qdrant"
else
  QDRANT_EXECUTABLE="./target/debug/qdrant"
fi

# Enable distributed mode on demand
if [ "$MODE" == "distributed" ]; then
  export QDRANT__CLUSTER__ENABLED="true"
  # Run in background
  $QDRANT_EXECUTABLE --uri "http://127.0.0.1:6335" &
else
  # Run in background
  $QDRANT_EXECUTABLE &
fi

## Capture PID of the run
PID=$!
echo $PID

function clear_after_tests()
{
  echo "server is going down"

  if [ "$COVERAGE" == "1" ]; then
    kill -2 $PID # interrupt instead of kill to allow graceful shutdown so we can get the coverage
    wait $PID
  else
    kill -9 $PID
  fi

  echo "END"
}

trap clear_after_tests SIGINT
trap clear_after_tests EXIT

MAX_RETRIES=24
retry=0
until [ "$retry" -ge "$MAX_RETRIES" ]; do
  status_code=$($CURL_BIN --noproxy "*" --output /dev/null --silent --get --write-out "%{http_code}" "$BASE_URL/collections" || true)

  # In some shells/environments localhost and 127.0.0.1 behave differently.
  # If primary host fails, try alternate loopback host.
  if [ "$status_code" != "200" ]; then
    if [ "$QDRANT_HOST" = "127.0.0.1:6333" ]; then
      ALT_QDRANT_HOST="localhost:6333"
    elif [ "$QDRANT_HOST" = "localhost:6333" ]; then
      ALT_QDRANT_HOST="127.0.0.1:6333"
    else
      ALT_QDRANT_HOST=""
    fi

    if [ -n "$ALT_QDRANT_HOST" ]; then
      alt_status_code=$($CURL_BIN --noproxy "*" --output /dev/null --silent --get --write-out "%{http_code}" "http://$ALT_QDRANT_HOST$QDRANT_BASE_PATH/collections" || true)
      if [ "$alt_status_code" = "200" ]; then
        QDRANT_HOST="$ALT_QDRANT_HOST"
        BASE_URL="http://$QDRANT_HOST$QDRANT_BASE_PATH"
        export QDRANT_HOST
        status_code="200"
      fi
    fi
  fi

  if [ "$status_code" = "200" ]; then
    break
  fi

  retry=$((retry + 1))
  printf 'waiting for server to start... (%s/%s, /collections -> %s)\n' "$retry" "$MAX_RETRIES" "$status_code"
  sleep 5
done

if [ "$status_code" != "200" ]; then
  echo "Qdrant did not become ready at $BASE_URL/collections (last status: $status_code)" >&2
  echo "Readiness probe used: $CURL_BIN"
  echo "Debug hint: verify base path and auth env vars."
  echo "QDRANT_BASE_PATH='${QDRANT_BASE_PATH}'"
  echo "QDRANT__SERVICE__BASE_PATH='${QDRANT__SERVICE__BASE_PATH:-}'"
  echo "QDRANT__SERVICE__API_KEY set: ${QDRANT__SERVICE__API_KEY:+yes}${QDRANT__SERVICE__API_KEY:-no}" | sed 's/yesno/no/'
  echo "QDRANT__SERVICE__READ_ONLY_API_KEY set: ${QDRANT__SERVICE__READ_ONLY_API_KEY:+yes}${QDRANT__SERVICE__READ_ONLY_API_KEY:-no}" | sed 's/yesno/no/'
  exit 1
fi

echo "server ready to serve traffic"

# Wait for the peer to establish the leader and commit initial settings
if [ "$MODE" == "distributed" ]; then
  sleep 10
fi

UV_BIN=""
if command -v uv >/dev/null 2>&1; then
  UV_BIN="uv"
elif command -v uv.exe >/dev/null 2>&1; then
  UV_BIN="uv.exe"
elif [ -n "${USERNAME:-}" ] && [ -x "/c/Users/${USERNAME}/AppData/Local/Microsoft/WinGet/Packages/astral-sh.uv_Microsoft.Winget.Source_8wekyb3d8bbwe/uv.exe" ]; then
  UV_BIN="/c/Users/${USERNAME}/AppData/Local/Microsoft/WinGet/Packages/astral-sh.uv_Microsoft.Winget.Source_8wekyb3d8bbwe/uv.exe"
elif [ -n "${USERNAME:-}" ] && [ -x "/mnt/c/Users/${USERNAME}/AppData/Local/Microsoft/WinGet/Packages/astral-sh.uv_Microsoft.Winget.Source_8wekyb3d8bbwe/uv.exe" ]; then
  UV_BIN="/mnt/c/Users/${USERNAME}/AppData/Local/Microsoft/WinGet/Packages/astral-sh.uv_Microsoft.Winget.Source_8wekyb3d8bbwe/uv.exe"
fi

if [ -n "$UV_BIN" ]; then
  "$UV_BIN" --project tests sync
  "$UV_BIN" --project tests run pytest tests/openapi --durations=10
else
  python -m pytest tests/openapi --durations=10
fi

./tests/basic_api_test.sh

./tests/basic_sparse_test.sh

./tests/basic_grpc_test.sh

./tests/basic_sparse_grpc_test.sh

./tests/basic_multivector_grpc_test.sh

./tests/basic_query_grpc_test.sh
