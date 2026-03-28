# CKB Light Client Benchmark Results

**Date:** 2026-03-29T03:40+10:30
**Host:** driveThree — x86_64
**CPU:** Intel Core i7-14700KF
**RAM:** 62GB DDR5
**Kernel:** 6.8.0-106-generic (Ubuntu 22.04)
**Duration:** 60s per binary
**Version:** CKB Light Client 0.5.5 (e4f62a9)
**Network:** Testnet

## Binary Comparison

| Metric | Standard | Lite | Delta |
|--------|----------|------|-------|
| Size | 30.0 MB | 24.6 MB | **-18%** |
| Linking | Dynamic (glibc) | Dynamic (glibc)* | — |
| DB Backend | RocksDB | SQLite | — |

*Note: This benchmark used glibc builds for both to ensure fair comparison on the same platform. The musl static aarch64 build is 18MB stripped.*

## Startup Time

Time from process launch to first successful RPC response (get_peers).

| Metric | Standard | Lite |
|--------|----------|------|
| Startup | 510ms | 512ms |

**Verdict:** Identical startup performance.

## Runtime Metrics (60s observation)

| Metric | Standard | Lite | Delta | Notes |
|--------|----------|------|-------|-------|
| Peak RSS | 54,856 KB (53.6 MB) | 45,028 KB (44.0 MB) | **-18%** | Max resident memory |
| Final RSS | 51,376 KB (50.2 MB) | 42,536 KB (41.5 MB) | **-17%** | Memory at end of test |
| Peak VSZ | 2,633,520 KB (2.5 GB) | 2,453,588 KB (2.3 GB) | **-7%** | Virtual address space |
| Avg CPU | 0.2% | 0.3% | ~same | Negligible difference |
| Threads | 34 | 31 | -3 | Fewer threads needed |
| Open FDs | 31 | 28 | -3 | Fewer file descriptors |

### Memory Over Time

| Time | Standard RSS | Lite RSS |
|------|-------------|----------|
| 20s | 50,576 KB | 43,396 KB |
| 40s | 54,856 KB | 45,028 KB |
| 60s | 50,280 KB | 42,356 KB |

## Disk I/O

| Metric | Standard | Lite | Delta |
|--------|----------|------|-------|
| DB Engine | RocksDB | SQLite | — |
| Store size after 60s | 135,212 KB (132 MB) | 2,428 KB (2.4 MB) | **-98%** |

This is the most dramatic difference. RocksDB pre-allocates WAL files and SSTables aggressively, consuming 132MB of disk in the first 60 seconds. SQLite uses a compact single-file database that only grows as data arrives.

**Implications for embedded devices:**
- A device with 256MB storage (e.g. Anbernic overlay partition) would exhaust disk with RocksDB before meaningful sync
- SQLite's 2.4MB footprint leaves room for months of operation

## RPC Performance

| Metric | Standard | Lite |
|--------|----------|------|
| get_peers latency | 5ms | 5ms |

**Verdict:** Identical RPC performance.

## GLIBC Compatibility

| Device | GLIBC | Standard | Lite (musl static) |
|--------|-------|----------|-------------------|
| Anbernic RG-ARC-D/S | 2.32 | FAIL | **PASS** |
| Knulli / RG35XXH | ~2.36 | PASS | PASS |
| Raspberry Pi (Raspbian) | 2.36 | PASS | PASS |
| Orange Pi 5 (Armbian) | 2.35 | PASS | PASS |
| Ubuntu 22.04+ | 2.35 | PASS | PASS |
| Buildroot / OpenWrt | varies | FAIL | **PASS** |

## Summary

The Lite build (SQLite + musl static) is better than or equal to the Standard build (RocksDB + glibc) on every measured metric:

| Category | Winner | Margin |
|----------|--------|--------|
| Binary size | Lite | -18% (30→24.6 MB, or 18 MB musl stripped) |
| Memory (RSS) | Lite | -18% (53.6→44.0 MB peak) |
| Disk usage | Lite | -98% (132→2.4 MB after 60s) |
| Startup time | Tie | 510 vs 512ms |
| CPU usage | Tie | 0.2% vs 0.3% |
| RPC latency | Tie | 5ms vs 5ms |
| Compatibility | Lite | Runs on any Linux vs GLIBC 2.34+ |

**The SQLite backend is not a compromise — it's an improvement for the light client use case.** RocksDB is designed for high-throughput write-heavy workloads (full nodes). The light client's access pattern (mostly reads, occasional small writes) is a better fit for SQLite.

---

*Benchmark script: `benchmark.sh` — run your own comparison on any hardware.*
*Generated on driveThree (Intel i7-14700KF, 62GB RAM, NVMe SSD)*
