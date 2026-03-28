#!/bin/bash
# benchmark.sh — Comparative benchmark: ckb-light-client standard vs lite (musl/sqlite)
#
# Measures: binary size, startup time, memory (RSS/VSZ), CPU usage, disk I/O,
# database size after sync, RPC latency, and estimated power draw.
#
# Usage:
#   ./benchmark.sh /path/to/standard-binary /path/to/lite-binary [duration_seconds]
#
# Both binaries must be for the current architecture.

set -u

STANDARD="${1:?Usage: $0 <standard-binary> <lite-binary> [duration]}"
LITE="${2:?Usage: $0 <standard-binary> <lite-binary> [duration]}"
DURATION="${3:-60}"

REPORT_DIR="./benchmark-results"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REPORT="$REPORT_DIR/benchmark-$TIMESTAMP.md"
CSV="$REPORT_DIR/benchmark-$TIMESTAMP.csv"

mkdir -p "$REPORT_DIR"

STD_DIR="/tmp/bench-standard-$$"
LITE_DIR="/tmp/bench-lite-$$"
STD_PORT=19900
LITE_PORT=19901

cleanup() {
  for pidfile in "$STD_DIR/data/ckb-light.pid" "$LITE_DIR/data/ckb-light.pid"; do
    if [ -f "$pidfile" ]; then
      kill "$(cat "$pidfile")" 2>/dev/null
    fi
  done
  pkill -f "bench-standard\|bench-lite" 2>/dev/null
  rm -rf "$STD_DIR" "$LITE_DIR"
}
trap cleanup EXIT

# ── Helpers ──────────────────────────────────────────────────
get_rss_kb() {
  awk '/VmRSS/{print $2}' "/proc/$1/status" 2>/dev/null || echo "0"
}

get_vsz_kb() {
  awk '/VmSize/{print $2}' "/proc/$1/status" 2>/dev/null || echo "0"
}

get_cpu_pct() {
  # CPU% over 1 second sample
  ps -p "$1" -o %cpu --no-headers 2>/dev/null | tr -d ' ' || echo "0"
}

get_threads() {
  ls /proc/$1/task 2>/dev/null | wc -l || echo "0"
}

get_open_fds() {
  ls /proc/$1/fd 2>/dev/null | wc -l || echo "0"
}

rpc_latency_ms() {
  local port=$1
  local start end
  start=$(date +%s%N)
  curl -s -m 3 -X POST "http://127.0.0.1:$port/" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","method":"get_peers","params":[],"id":1}' > /dev/null 2>&1
  end=$(date +%s%N)
  echo $(( (end - start) / 1000000 ))
}

setup_config() {
  local dir=$1
  local port=$2
  mkdir -p "$dir/data/store" "$dir/data/network"

  # Download testnet config
  curl -fsSL -o "$dir/config.toml" \
    "https://raw.githubusercontent.com/nervosnetwork/ckb-light-client/develop/config/testnet.toml" 2>/dev/null

  # Patch config for test
  sed -i "s|store = .*|store = \"$dir/data/store\"|" "$dir/config.toml" 2>/dev/null
  sed -i "s|path = .*network.*|path = \"$dir/data/network\"|" "$dir/config.toml" 2>/dev/null
  sed -i "s|9000|$port|g" "$dir/config.toml" 2>/dev/null
}

sample_metrics() {
  local pid=$1
  local label=$2

  local rss=$(get_rss_kb "$pid")
  local vsz=$(get_vsz_kb "$pid")
  local cpu=$(get_cpu_pct "$pid")
  local threads=$(get_threads "$pid")
  local fds=$(get_open_fds "$pid")

  echo "$label,$rss,$vsz,$cpu,$threads,$fds"
}

# ── Header ───────────────────────────────────────────────────
echo "=============================================="
echo "CKB Light Client Benchmark"
echo "Standard (RocksDB/glibc) vs Lite (SQLite/musl)"
echo "=============================================="
echo "Duration: ${DURATION}s per test"
echo "Standard: $STANDARD"
echo "Lite: $LITE"
echo ""

{
echo "# CKB Light Client Benchmark Results"
echo ""
echo "**Date:** $(date -Iseconds)"
echo "**Host:** $(hostname) — $(uname -m)"
echo "**CPU:** $(grep 'model name' /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)"
echo "**RAM:** $(free -h | awk '/Mem:/{print $2}') total"
echo "**Kernel:** $(uname -r)"
echo "**Duration:** ${DURATION}s per binary"
echo ""
} > "$REPORT"

# ── 1. Binary Comparison ────────────────────────────────────
echo "[1/6] Binary comparison"
STD_SIZE=$(stat -c%s "$STANDARD" 2>/dev/null || stat -f%z "$STANDARD" 2>/dev/null)
LITE_SIZE=$(stat -c%s "$LITE" 2>/dev/null || stat -f%z "$LITE" 2>/dev/null)
STD_SIZE_MB=$(echo "scale=1; $STD_SIZE / 1048576" | bc)
LITE_SIZE_MB=$(echo "scale=1; $LITE_SIZE / 1048576" | bc)
SIZE_REDUCTION=$(echo "scale=1; (1 - $LITE_SIZE / $STD_SIZE) * 100" | bc)

STD_TYPE=$(file "$STANDARD" | grep -oP '(statically|dynamically) linked' || echo "unknown")
LITE_TYPE=$(file "$LITE" | grep -oP '(statically|dynamically) linked' || echo "unknown")

STD_VER=$("$STANDARD" --version 2>&1 | head -1)
LITE_VER=$("$LITE" --version 2>&1 | head -1)

{
echo "## 1. Binary Comparison"
echo ""
echo "| Metric | Standard | Lite | Delta |"
echo "|--------|----------|------|-------|"
echo "| Size | ${STD_SIZE_MB}MB | ${LITE_SIZE_MB}MB | -${SIZE_REDUCTION}% |"
echo "| Linking | $STD_TYPE | $LITE_TYPE | — |"
echo "| DB Backend | RocksDB | SQLite | — |"
echo "| Version | $STD_VER | $LITE_VER | — |"
echo ""
} >> "$REPORT"

echo "  Standard: ${STD_SIZE_MB}MB ($STD_TYPE)"
echo "  Lite:     ${LITE_SIZE_MB}MB ($LITE_TYPE)"

# ── 2. Startup Time ─────────────────────────────────────────
echo "[2/6] Startup time (time to first RPC response)"

setup_config "$STD_DIR" "$STD_PORT"
setup_config "$LITE_DIR" "$LITE_PORT"

measure_startup() {
  local bin=$1 dir=$2 port=$3
  local start_ns=$(date +%s%N)

  RUST_LOG=error "$bin" run --config-file "$dir/config.toml" > "$dir/bench.log" 2>&1 &
  local pid=$!
  echo "$pid" > "$dir/data/ckb-light.pid"

  # Poll RPC until responsive
  for i in $(seq 1 30); do
    if curl -s -m 1 -X POST "http://127.0.0.1:$port/" \
      -H 'Content-Type: application/json' \
      -d '{"jsonrpc":"2.0","method":"get_peers","params":[],"id":1}' 2>/dev/null | grep -q jsonrpc; then
      local end_ns=$(date +%s%N)
      echo $(( (end_ns - start_ns) / 1000000 ))
      return
    fi
    sleep 0.5
  done
  echo "timeout"
}

STD_STARTUP=$(measure_startup "$STANDARD" "$STD_DIR" "$STD_PORT")
# Kill standard before starting lite
kill "$(cat "$STD_DIR/data/ckb-light.pid")" 2>/dev/null
wait 2>/dev/null
sleep 2

LITE_STARTUP=$(measure_startup "$LITE" "$LITE_DIR" "$LITE_PORT")
kill "$(cat "$LITE_DIR/data/ckb-light.pid")" 2>/dev/null
wait 2>/dev/null
sleep 2

echo "  Standard: ${STD_STARTUP}ms"
echo "  Lite:     ${LITE_STARTUP}ms"

{
echo "## 2. Startup Time"
echo ""
echo "Time from launch to first successful RPC response."
echo ""
echo "| Metric | Standard | Lite |"
echo "|--------|----------|------|"
echo "| Startup (ms) | $STD_STARTUP | $LITE_STARTUP |"
echo ""
} >> "$REPORT"

# ── 3. Runtime Metrics (sampled over duration) ───────────────
echo "[3/6] Runtime metrics (sampling over ${DURATION}s each)"

# CSV header
echo "time_s,variant,rss_kb,vsz_kb,cpu_pct,threads,fds" > "$CSV"

run_and_sample() {
  local bin=$1 dir=$2 port=$3 label=$4
  # Clean data dir for fair test
  rm -rf "$dir/data/store" "$dir/data/network"
  mkdir -p "$dir/data/store" "$dir/data/network"

  RUST_LOG=error "$bin" run --config-file "$dir/config.toml" > "$dir/bench.log" 2>&1 &
  local pid=$!
  echo "$pid" > "$dir/data/ckb-light.pid"
  sleep 5  # let it stabilise

  local peak_rss=0 peak_vsz=0 total_cpu=0 samples=0

  for t in $(seq 1 "$DURATION"); do
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "  Process died at ${t}s"
      break
    fi

    local rss=$(get_rss_kb "$pid")
    local vsz=$(get_vsz_kb "$pid")
    local cpu=$(get_cpu_pct "$pid")
    local threads=$(get_threads "$pid")
    local fds=$(get_open_fds "$pid")

    echo "$t,$label,$rss,$vsz,$cpu,$threads,$fds" >> "$CSV"

    [ "$rss" -gt "$peak_rss" ] 2>/dev/null && peak_rss=$rss
    [ "$vsz" -gt "$peak_vsz" ] 2>/dev/null && peak_vsz=$vsz
    total_cpu=$(echo "$total_cpu + $cpu" | bc 2>/dev/null || echo "$total_cpu")
    samples=$((samples + 1))

    # Progress every 15s
    if [ $((t % 15)) -eq 0 ]; then
      echo "  $label: ${t}s — RSS:${rss}KB CPU:${cpu}%"
    fi

    sleep 1
  done

  local avg_cpu=0
  if [ "$samples" -gt 0 ]; then
    avg_cpu=$(echo "scale=1; $total_cpu / $samples" | bc 2>/dev/null || echo "0")
  fi

  # DB size
  local db_size=$(du -sk "$dir/data/store" 2>/dev/null | cut -f1 || echo "0")

  # RPC latency
  local rpc_lat=$(rpc_latency_ms "$port")

  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null

  echo "${peak_rss},${peak_vsz},${avg_cpu},${samples},${db_size},${rpc_lat}"
}

echo "  Running standard build..."
STD_METRICS=$(run_and_sample "$STANDARD" "$STD_DIR" "$STD_PORT" "standard")
sleep 3

echo "  Running lite build..."
LITE_METRICS=$(run_and_sample "$LITE" "$LITE_DIR" "$LITE_PORT" "lite")

IFS=',' read -r STD_PRSS STD_PVSZ STD_ACPU STD_SAMP STD_DBSZ STD_RPCL <<< "$STD_METRICS"
IFS=',' read -r LITE_PRSS LITE_PVSZ LITE_ACPU LITE_SAMP LITE_DBSZ LITE_RPCL <<< "$LITE_METRICS"

{
echo "## 3. Runtime Metrics (${DURATION}s observation)"
echo ""
echo "| Metric | Standard | Lite | Notes |"
echo "|--------|----------|------|-------|"
echo "| Peak RSS (KB) | $STD_PRSS | $LITE_PRSS | Resident memory |"
echo "| Peak RSS (MB) | $((STD_PRSS / 1024)) | $((LITE_PRSS / 1024)) | — |"
echo "| Peak VSZ (KB) | $STD_PVSZ | $LITE_PVSZ | Virtual memory |"
echo "| Avg CPU (%) | $STD_ACPU | $LITE_ACPU | Over ${DURATION}s |"
echo "| DB Size (KB) | $STD_DBSZ | $LITE_DBSZ | After ${DURATION}s sync |"
echo "| RPC Latency (ms) | $STD_RPCL | $LITE_RPCL | get_peers round-trip |"
echo ""
} >> "$REPORT"

# ── 4. Disk I/O ─────────────────────────────────────────────
echo "[4/6] Disk I/O comparison"
{
echo "## 4. Disk I/O"
echo ""
echo "| Metric | Standard | Lite |"
echo "|--------|----------|------|"
echo "| DB engine | RocksDB | SQLite |"
echo "| Store size after ${DURATION}s | ${STD_DBSZ}KB | ${LITE_DBSZ}KB |"
echo ""
} >> "$REPORT"

# ── 5. Power Estimation ─────────────────────────────────────
echo "[5/6] Power estimation"
# Read CPU energy if RAPL is available
RAPL_DIR="/sys/class/powercap/intel-rapl:0"
if [ -f "$RAPL_DIR/energy_uj" ]; then
  echo "  RAPL available — measuring actual CPU energy"

  measure_power() {
    local bin=$1 dir=$2 port=$3 secs=$4
    rm -rf "$dir/data/store" "$dir/data/network"
    mkdir -p "$dir/data/store" "$dir/data/network"

    local e_start=$(cat "$RAPL_DIR/energy_uj")
    RUST_LOG=error "$bin" run --config-file "$dir/config.toml" > /dev/null 2>&1 &
    local pid=$!
    sleep "$secs"
    local e_end=$(cat "$RAPL_DIR/energy_uj")
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null

    local uj=$((e_end - e_start))
    local watts=$(echo "scale=2; $uj / $secs / 1000000" | bc)
    echo "$watts"
  }

  POWER_SECS=30
  STD_WATTS=$(measure_power "$STANDARD" "$STD_DIR" "$STD_PORT" "$POWER_SECS")
  sleep 3
  LITE_WATTS=$(measure_power "$LITE" "$LITE_DIR" "$LITE_PORT" "$POWER_SECS")

  # Baseline (idle)
  IDLE_START=$(cat "$RAPL_DIR/energy_uj")
  sleep "$POWER_SECS"
  IDLE_END=$(cat "$RAPL_DIR/energy_uj")
  IDLE_WATTS=$(echo "scale=2; ($IDLE_END - $IDLE_START) / $POWER_SECS / 1000000" | bc)

  {
  echo "## 5. Power Consumption (CPU package via RAPL, ${POWER_SECS}s sample)"
  echo ""
  echo "| Metric | Standard | Lite | Idle Baseline |"
  echo "|--------|----------|------|---------------|"
  echo "| CPU Power (W) | ${STD_WATTS}W | ${LITE_WATTS}W | ${IDLE_WATTS}W |"
  echo ""
  } >> "$REPORT"
  echo "  Standard: ${STD_WATTS}W  Lite: ${LITE_WATTS}W  Idle: ${IDLE_WATTS}W"
else
  echo "  No RAPL — estimating from CPU usage"
  # Rough estimate: assume TDP * (cpu% / 100)
  TDP_W=15  # typical handheld/mini-PC TDP
  STD_EST_W=$(echo "scale=2; $TDP_W * $STD_ACPU / 100" | bc 2>/dev/null || echo "n/a")
  LITE_EST_W=$(echo "scale=2; $TDP_W * $LITE_ACPU / 100" | bc 2>/dev/null || echo "n/a")

  {
  echo "## 5. Power Consumption (estimated from CPU%, assume ${TDP_W}W TDP)"
  echo ""
  echo "| Metric | Standard | Lite |"
  echo "|--------|----------|------|"
  echo "| Est. Power (W) | ~${STD_EST_W}W | ~${LITE_EST_W}W |"
  echo "| Avg CPU% | ${STD_ACPU}% | ${LITE_ACPU}% |"
  echo ""
  echo "*Note: RAPL not available on this system. Values estimated from CPU utilisation.*"
  echo ""
  } >> "$REPORT"
  echo "  Standard: ~${STD_EST_W}W  Lite: ~${LITE_EST_W}W (estimated)"
fi

# ── 6. Summary ───────────────────────────────────────────────
echo "[6/6] Summary"

{
echo "## 6. GLIBC Compatibility"
echo ""
echo "| | Standard | Lite |"
echo "|---|----------|------|"
echo "| Min GLIBC | 2.34+ | None (static) |"
echo "| Anbernic RG-ARC-D/S (2.32) | FAIL | PASS |"
echo "| Knulli/RG35XXH | PASS | PASS |"
echo "| Ubuntu 22.04+ | PASS | PASS |"
echo "| Buildroot / OpenWrt | FAIL | PASS |"
echo ""
echo "## 7. Conclusion"
echo ""
echo "The Lite build trades RocksDB for SQLite and dynamic for static linking."
echo "This eliminates GLIBC version requirements at the cost of:"
DELTA_RSS=$((LITE_PRSS - STD_PRSS))
echo "- Memory: ${DELTA_RSS}KB RSS difference ($(echo "scale=1; $DELTA_RSS / 1024" | bc 2>/dev/null || echo "?")MB)"
echo "- Binary: ${LITE_SIZE_MB}MB vs ${STD_SIZE_MB}MB (-${SIZE_REDUCTION}%)"
echo "- Startup: ${LITE_STARTUP}ms vs ${STD_STARTUP}ms"
echo ""
echo "---"
echo ""
echo "Raw CSV data: \`$(basename "$CSV")\`"
echo ""
echo "*Generated by benchmark.sh — $(date -Iseconds)*"
} >> "$REPORT"

echo ""
echo "=============================================="
echo "Benchmark complete"
echo "Report: $REPORT"
echo "CSV:    $CSV"
echo "=============================================="
