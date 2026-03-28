# CKB Light Client Lite

Statically linked builds of the [CKB Light Client](https://github.com/nervosnetwork/ckb-light-client) for embedded and constrained Linux devices.

**Why?** The official binaries require GLIBC 2.34+ and use RocksDB, which limits compatibility. This project builds the same source code with:

- **Static linking** via musl libc — zero system dependencies
- **SQLite** backend instead of RocksDB — lighter, more portable
- **Pre-built binaries** for aarch64 and x86_64

Runs on any Linux regardless of GLIBC version — from Buildroot handhelds to Raspberry Pi to full desktop.

## Download

Pre-built binaries are available from [Releases](https://github.com/toastmanAu/ckb-light-client-lite/releases).

| Architecture | Binary | Size |
|-------------|--------|------|
| aarch64 (ARM64) | `ckb-light-client-*-aarch64-linux-musl-static.tar.gz` | ~9MB |
| x86_64 (Intel/AMD) | `ckb-light-client-*-x86_64-linux-musl-static.tar.gz` | ~9MB |

## Quick Start

```bash
# Download (aarch64 example)
curl -fsSL -o ckb-light.tar.gz \
  https://github.com/toastmanAu/ckb-light-client-lite/releases/latest/download/ckb-light-client-aarch64-linux-musl-static.tar.gz

# Extract
tar xzf ckb-light.tar.gz

# Download testnet config
curl -fsSL -o config.toml \
  https://raw.githubusercontent.com/nervosnetwork/ckb-light-client/develop/config/testnet.toml

# Run
./ckb-light-client run --config-file config.toml
```

## Build from Source

Requirements: Rust 1.92+, musl cross-compiler

```bash
# Clone upstream
git clone --depth 1 https://github.com/nervosnetwork/ckb-light-client.git
cd ckb-light-client

# Install musl cross-compiler (aarch64)
curl -fsSL -o /tmp/musl-cross.tgz https://musl.cc/aarch64-linux-musl-cross.tgz
tar xzf /tmp/musl-cross.tgz -C /tmp/

# Add Rust target
rustup target add aarch64-unknown-linux-musl

# Configure linker
mkdir -p .cargo
cat > .cargo/config.toml << EOF
[target.aarch64-unknown-linux-musl]
linker = "/tmp/aarch64-linux-musl-cross/bin/aarch64-linux-musl-gcc"
EOF

# Build
export CC_aarch64_unknown_linux_musl=/tmp/aarch64-linux-musl-cross/bin/aarch64-linux-musl-gcc
export CXX_aarch64_unknown_linux_musl=/tmp/aarch64-linux-musl-cross/bin/aarch64-linux-musl-g++
export AR_aarch64_unknown_linux_musl=/tmp/aarch64-linux-musl-cross/bin/aarch64-linux-musl-ar

cd light-client-bin
cargo build --release --target aarch64-unknown-linux-musl \
  --no-default-features --features sqlite

# Strip
/tmp/aarch64-linux-musl-cross/bin/aarch64-linux-musl-strip \
  ../target/aarch64-unknown-linux-musl/release/ckb-light-client
```

## Standard vs Lite Comparison

_Benchmark results will be added after running `benchmark.sh`._

## What Changes from Upstream

| | Official Build | Lite Build |
|---|---------------|-----------|
| Linking | Dynamic (glibc) | Static (musl) |
| DB Backend | RocksDB | SQLite |
| Min GLIBC | 2.34 | None |
| Binary Size | ~30MB | ~18MB |
| Platforms | Ubuntu 22.04+ | Any Linux |

**What does NOT change:**
- Same source code (nervosnetwork/ckb-light-client)
- Same P2P networking, sync protocol, RPC API
- Same cryptographic verification
- Same config file format
- Compatible with official CKB nodes

## Testing

```bash
# Run test suite on target device
bash tests/test-light-client-musl.sh /path/to/ckb-light-client

# Run benchmark (requires both standard and lite binaries)
bash benchmark.sh /path/to/standard /path/to/lite 60
```

## Tested Devices

| Device | OS | GLIBC | Official | Lite |
|--------|-----|-------|----------|------|
| Anbernic RG-ARC-D/S | Buildroot | 2.32 | FAIL | PASS |
| Anbernic RG35XXH | Knulli | TBD | TBD | TBD |
| Raspberry Pi 4/5 | Raspbian | 2.36 | PASS | PASS |
| Orange Pi 5 | Armbian | 2.35 | PASS | PASS |
| x86_64 Desktop | Ubuntu 22.04 | 2.35 | PASS | PASS |

## CI/CD

GitHub Actions automatically:
1. Checks for new upstream releases weekly
2. Cross-compiles musl static binaries for aarch64 + x86_64
3. Publishes to GitHub Releases

Manual builds can be triggered via `workflow_dispatch` with a specific upstream tag.

## License

Same as upstream: MIT — see [nervosnetwork/ckb-light-client](https://github.com/nervosnetwork/ckb-light-client/blob/develop/LICENSE)
