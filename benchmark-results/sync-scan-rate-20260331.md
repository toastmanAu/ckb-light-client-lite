# CKB Light Client Sync Scan Rate: RocksDB vs SQLite

## Filter Scan Performance from Block 0 (Cold Start)

**Date:** 2026-03-31
**Host:** driveThree — x86_64
**CPU:** Intel Core i7-14700KF
**RAM:** 62GB DDR5
**Kernel:** 6.8.0-106-generic (Ubuntu 22.04)
**Duration:** 30 minutes per run (timeout)
**Network:** CKB Mainnet
**Version:** CKB Light Client 0.5.5-rc1 (e4f62a9)
**Runs:** 4 total (R1, S1, R2, S2) — alternating backend, OS cache dropped between runs

## Methodology

Each run starts a fresh light client instance with no prior data, registers a single mainnet address via `set_scripts` from block 0, and lets it scan block filters for 30 minutes. Progress is sampled every 30 seconds.

This measures the raw **filter scan rate** — how fast the light client can process block headers and check compact filters against a registered address. This is the primary bottleneck for cold-start wallet sync.

## Results

### Blocks Scanned in 30 Minutes

| Run | Backend | Blocks Scanned | Avg Rate (blocks/sec) | Peak RSS | Disk After 30min |
|-----|---------|---------------|----------------------|----------|------------------|
| R1 | RocksDB | 648,000 | ~362/s | 64.6 MB | **132 MB** |
| S1 | SQLite | 842,000 | ~469/s | 59.6 MB | **5.8 MB** |
| R2 | RocksDB | 750,000 | ~417/s | 62.0 MB | **132 MB** |
| S2 | SQLite | 872,000 | ~484/s | 55.8 MB | **5.8 MB** |

### Averages

| Metric | RocksDB (avg) | SQLite (avg) | Delta |
|--------|---------------|--------------|-------|
| Blocks scanned | 699,000 | 858,000 | **+23% (SQLite)** |
| Scan rate | ~389/s | ~477/s | **+23% faster** |
| Peak RSS | 63.3 MB | 57.7 MB | **-9% less memory** |
| Disk usage | 132 MB | 5.8 MB | **-96% less disk** |

### Extrapolated Time to Scan Full Mainnet (~19M blocks)

| Backend | At Observed Rate | Estimated Full Scan Time |
|---------|-----------------|--------------------------|
| RocksDB | ~389 blocks/sec | ~13.5 hours |
| SQLite | ~477 blocks/sec | ~11.1 hours |

*Note: Scan rate may vary as chain data density changes across epochs. These rates are from the first 700-870K blocks (epochs 0-~80) where blocks are relatively sparse.*

## Scan Rate Over Time

Both backends show consistent scan rates throughout the 30-minute window. No degradation observed.

**RocksDB R1 (sampled every 30s):**
```
  30s:       0 blocks  (startup/peer discovery)
  60s:       0 blocks  (syncing headers)
  90s:   5,000 blocks  (scanning begins)
 300s:  74,000 blocks  (~330/s)
 600s: 189,000 blocks  (~340/s)
 900s: 327,000 blocks  (~363/s)
1200s: 414,000 blocks  (~345/s)
1500s: 519,000 blocks  (~346/s)
1788s: 648,000 blocks  (~362/s)
```

**SQLite S1 (sampled every 30s):**
```
  30s:       0 blocks
  60s:   6,000 blocks
  90s:  18,000 blocks
 300s: 118,000 blocks  (~393/s)
 600s: 268,000 blocks  (~447/s)
 900s: 434,000 blocks  (~482/s)
1200s: 582,000 blocks  (~485/s)
1500s: 719,000 blocks  (~479/s)
1788s: 842,000 blocks  (~471/s)
```

## Disk Growth

The most dramatic difference. RocksDB pre-allocates WAL files and SSTables immediately, consuming 132MB within the first minute. SQLite grows proportionally to data received.

| Time | RocksDB | SQLite |
|------|---------|--------|
| 1 min | 132 MB | ~1 MB |
| 10 min | 132 MB | ~3 MB |
| 30 min | 132 MB | 5.8 MB |

**Impact on embedded devices:** A device with 256MB of storage (e.g. Anbernic overlay partition) would exhaust available space with RocksDB before meaningful sync begins. SQLite leaves room for months of operation.

## What This Means

1. **SQLite scans 23% more blocks** in the same time window — faster filter matching and lighter I/O profile
2. **Disk usage is 96% lower** — critical for mobile and embedded devices
3. **Memory is 9% lower** — modest but meaningful on constrained hardware
4. **Both backends are identical in correctness** — they scan the same chain, process the same filters

For wallet developers using the CKB light client:
- Cold-start sync (new wallet, no prior state) takes **11-14 hours** regardless of backend
- The real win for SQLite is **storage footprint** — enables light client on devices where RocksDB can't fit
- For daily wallet use (warm start), see the pre-synced benchmark (forthcoming)

## Reproduction

```bash
# Build both variants from nervosnetwork/ckb-light-client v0.5.5-rc1
cd /path/to/ckb-light-client
cargo build --release -p ckb-light-client                              # RocksDB
cargo build --release --no-default-features --features sqlite -p ckb-light-client  # SQLite

# Run with the benchmark script
./benchmark-sync.sh ./ckb-light-client-rocksdb ./ckb-light-client-sqlite 30
```

## Raw Data

Full CSV with 30-second samples: [`sync-progress-20260331_191448.csv`](sync-progress-20260331_191448.csv)

---

*CKB Light Client Lite project — https://github.com/toastmanAu/ckb-light-client-lite*
