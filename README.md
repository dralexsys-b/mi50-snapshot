# MI50 / gfx906 Infrastructure Snapshot Toolkit

> Production-grade disaster recovery toolkit for AMD Radeon VII / Instinct MI50 / MI60 (gfx906) inference stacks running on ROCm 7.x with patched Tensile blobs and iacopPBK/llama.cpp-gfx906 fork.

## What this does

This script creates a **reproducible snapshot** of your working MI50/gfx906 ML inference environment, including:

- ROCm runtime (with explicit symlink handling)
- gfx906 Tensile blobs (the resurrection patches that bring Vega 20 back to life on ROCm 7.x)
- llama.cpp source + compiled binaries + git state
- Launch scripts and working examples
- Environment configuration (.bashrc, APT repos)
- SHA256 integrity checks
- Post-restore runtime validation

## Philosophy

This script handles **inference-stack-level** recovery. For **system-level** recovery (kernel, DKMS, bootloader), use [Timeshift](https://github.com/linuxmint/timeshift).

The two layers together give you complete disaster recovery:

| Layer | Tool |
|-------|------|
| OS / Kernel / Bootloader | Timeshift |
| ROCm + llama.cpp + gfx906 patches | This script |

## Quick Start

### 1. Download

```bash
wget https://raw.githubusercontent.com/YOUR_USERNAME/mi50-snapshot/main/mi50_snapshot.sh
chmod +x mi50_snapshot.sh
