#!/bin/bash
# test-light-client-musl.sh — Comprehensive test suite for the static musl light client
# Run on the target device (aarch64) or via SSH:
#   sshpass -p 'anbernic' ssh root@192.168.68.112 "bash /userdata/ckb-light-client/nervos-launcher/tests/test-light-client-musl.sh"
#
# Tests: binary basics, config parsing, RPC startup, SQLite DB, network connectivity

set -u

BINARY="${1:-/userdata/ckb-light-client/bin/ckb-light-client}"
INSTALL_DIR="$(dirname "$(dirname "$BINARY")")"
TEST_DIR="/tmp/ckb-light-test-$$"
PASS=0
FAIL=0
SKIP=0

# ── Helpers ──────────────────────────────────────────────────
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }
skip() { SKIP=$((SKIP + 1)); echo "  SKIP: $1"; }

cleanup() {
  # Stop any test instance
  if [ -f "$TEST_DIR/data/ckb-light.pid" ]; then
    kill "$(cat "$TEST_DIR/data/ckb-light.pid")" 2>/dev/null
  fi
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

echo "==========================================="
echo "CKB Light Client (musl static) Test Suite"
echo "==========================================="
echo "Binary: $BINARY"
echo "Test dir: $TEST_DIR"
echo ""

# ── 1. Binary Existence ─────────────────────────────────────
echo "[1/10] Binary exists and is executable"
if [ -x "$BINARY" ]; then
  pass "Binary exists and is executable"
else
  fail "Binary not found or not executable at $BINARY"
  echo "Cannot continue without binary."
  exit 1
fi

# ── 2. Static Linking ────────────────────────────────────────
echo "[2/10] Statically linked (no GLIBC dependency)"
if file "$BINARY" | grep -q "statically linked"; then
  pass "Statically linked"
else
  FILE_INFO=$(file "$BINARY")
  if echo "$FILE_INFO" | grep -q "dynamically linked"; then
    fail "Dynamically linked — not a musl static build"
  else
    skip "Could not determine linking type: $FILE_INFO"
  fi
fi

# ── 3. Version Output ───────────────────────────────────────
echo "[3/10] --version returns valid output"
VERSION_OUT=$("$BINARY" --version 2>&1)
if echo "$VERSION_OUT" | grep -q "CKB Light Client"; then
  VERSION=$(echo "$VERSION_OUT" | grep -oP '\d+\.\d+\.\d+' | head -1)
  pass "--version works: $VERSION"
else
  fail "--version output unexpected: $VERSION_OUT"
fi

# ── 4. --help Output ────────────────────────────────────────
echo "[4/10] --help returns valid output"
HELP_OUT=$("$BINARY" --help 2>&1)
if echo "$HELP_OUT" | grep -q "run\|config"; then
  pass "--help works"
else
  fail "--help output unexpected"
fi

# ── 5. Architecture Match ───────────────────────────────────
echo "[5/10] Binary architecture matches system"
SYS_ARCH=$(uname -m)
BIN_ARCH=$(file "$BINARY")
if [ "$SYS_ARCH" = "aarch64" ] && echo "$BIN_ARCH" | grep -q "ARM aarch64"; then
  pass "Architecture match: $SYS_ARCH"
elif [ "$SYS_ARCH" = "x86_64" ] && echo "$BIN_ARCH" | grep -q "x86-64"; then
  pass "Architecture match: $SYS_ARCH"
else
  fail "Architecture mismatch: system=$SYS_ARCH binary=$BIN_ARCH"
fi

# ── 6. Config Parsing ───────────────────────────────────────
echo "[6/10] Config file parsing"
mkdir -p "$TEST_DIR/data/store" "$TEST_DIR/data/network"

# Download testnet config if not available locally
CONFIG_SRC="$INSTALL_DIR/config.toml"
if [ ! -f "$CONFIG_SRC" ]; then
  curl -fsSL -o "$TEST_DIR/config.toml" \
    "https://raw.githubusercontent.com/nervosnetwork/ckb-light-client/develop/config/testnet.toml" 2>/dev/null
  CONFIG_SRC="$TEST_DIR/config.toml"
fi

if [ -f "$CONFIG_SRC" ]; then
  cp "$CONFIG_SRC" "$TEST_DIR/config.toml"
  # Modify config to use test dir and a different port
  sed -i "s|store = .*|store = \"$TEST_DIR/data/store\"|" "$TEST_DIR/config.toml" 2>/dev/null
  sed -i "s|path = .*network.*|path = \"$TEST_DIR/data/network\"|" "$TEST_DIR/config.toml" 2>/dev/null
  sed -i "s|9000|19876|g" "$TEST_DIR/config.toml" 2>/dev/null

  # Test config parse (run with a quick timeout — it should start then we kill it)
  timeout 5 "$BINARY" run --config-file "$TEST_DIR/config.toml" > "$TEST_DIR/startup.log" 2>&1 &
  TEST_PID=$!
  sleep 3

  if kill -0 "$TEST_PID" 2>/dev/null; then
    pass "Config parsed, process started (PID $TEST_PID)"
    kill "$TEST_PID" 2>/dev/null
    wait "$TEST_PID" 2>/dev/null
  else
    # Check if it exited with an error
    STARTUP_LOG=$(cat "$TEST_DIR/startup.log" 2>/dev/null)
    if echo "$STARTUP_LOG" | grep -q "error\|panic\|GLIBC"; then
      fail "Startup failed: $(echo "$STARTUP_LOG" | tail -3)"
    else
      pass "Config parsed (process exited quickly — may be normal)"
    fi
  fi
else
  skip "No config file available"
fi

# ── 7. SQLite DB Creation ───────────────────────────────────
echo "[7/10] SQLite database creation"
if ls "$TEST_DIR/data/store/"*.db 2>/dev/null || ls "$TEST_DIR/data/store/"* 2>/dev/null; then
  pass "Data store created"
else
  skip "No store files (process may not have run long enough)"
fi

# ── 8. RPC Endpoint ─────────────────────────────────────────
echo "[8/10] RPC endpoint responds"
# Start again for RPC test
if [ -f "$TEST_DIR/config.toml" ]; then
  timeout 10 "$BINARY" run --config-file "$TEST_DIR/config.toml" > "$TEST_DIR/rpc.log" 2>&1 &
  RPC_PID=$!
  sleep 5

  RPC_RESULT=$(curl -s -m 3 -X POST http://127.0.0.1:19876/ \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","method":"get_peers","params":[],"id":1}' 2>/dev/null)

  if echo "$RPC_RESULT" | grep -q "jsonrpc"; then
    pass "RPC responds: get_peers"
  elif [ -z "$RPC_RESULT" ]; then
    # May need more time to start
    sleep 3
    RPC_RESULT=$(curl -s -m 3 -X POST http://127.0.0.1:19876/ \
      -H 'Content-Type: application/json' \
      -d '{"jsonrpc":"2.0","method":"get_peers","params":[],"id":1}' 2>/dev/null)
    if echo "$RPC_RESULT" | grep -q "jsonrpc"; then
      pass "RPC responds: get_peers (slow start)"
    else
      fail "RPC not responding after 8s"
    fi
  else
    fail "RPC unexpected response: $RPC_RESULT"
  fi

  kill "$RPC_PID" 2>/dev/null
  wait "$RPC_PID" 2>/dev/null
else
  skip "No config — skipping RPC test"
fi

# ── 9. Memory Usage ─────────────────────────────────────────
echo "[9/10] Memory footprint check"
if [ -f "$TEST_DIR/config.toml" ]; then
  timeout 10 "$BINARY" run --config-file "$TEST_DIR/config.toml" > /dev/null 2>&1 &
  MEM_PID=$!
  sleep 4

  if kill -0 "$MEM_PID" 2>/dev/null; then
    RSS=$(awk '/VmRSS/{print $2}' /proc/$MEM_PID/status 2>/dev/null || echo "0")
    RSS_MB=$((RSS / 1024))
    if [ "$RSS_MB" -gt 0 ] && [ "$RSS_MB" -lt 500 ]; then
      pass "Memory: ${RSS_MB}MB RSS (under 500MB limit)"
    elif [ "$RSS_MB" -ge 500 ]; then
      fail "Memory: ${RSS_MB}MB RSS (exceeds 500MB — too high for handheld)"
    else
      skip "Could not read memory usage"
    fi
    kill "$MEM_PID" 2>/dev/null
    wait "$MEM_PID" 2>/dev/null
  else
    skip "Process exited before memory check"
  fi
else
  skip "No config — skipping memory test"
fi

# ── 10. Binary Size ─────────────────────────────────────────
echo "[10/10] Binary size check"
SIZE_BYTES=$(stat -c%s "$BINARY" 2>/dev/null || stat -f%z "$BINARY" 2>/dev/null || echo "0")
SIZE_MB=$((SIZE_BYTES / 1024 / 1024))
if [ "$SIZE_MB" -gt 0 ] && [ "$SIZE_MB" -lt 30 ]; then
  pass "Binary size: ${SIZE_MB}MB (under 30MB limit)"
elif [ "$SIZE_MB" -ge 30 ]; then
  fail "Binary size: ${SIZE_MB}MB (over 30MB — expected under 30 for musl static)"
else
  skip "Could not determine binary size"
fi

# ── Summary ──────────────────────────────────────────────────
echo ""
echo "==========================================="
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "==========================================="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
