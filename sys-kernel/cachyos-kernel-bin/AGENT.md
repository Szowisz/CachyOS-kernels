# cachyos-kernel-bin Maintenance Guide for AI Agents

This document describes how to maintain `sys-kernel/cachyos-kernel-bin` ebuilds,
including adding new versions, syncing with upstream sources, and testing.

## Overview

`cachyos-kernel-bin` is a **pre-built binary kernel** package that downloads
compiled kernels from CachyOS mirrors (pacman `.pkg.tar.zst` format) and
installs them in Gentoo's dist-kernel layout. It inherits `kernel-install.eclass`
(NOT `kernel-build`), so it does NOT compile the kernel itself.

### Relationship to other packages

| Package | Role | Relationship |
|---------|------|--------------|
| `cachyos-sources` | Installs kernel sources (no build) | Shares version numbering, CachyOS release tags |
| `cachyos-kernel` | Builds kernel from source | Same CachyOS source tarball, offers more USE flags |
| `cachyos-kernel-bin` | Installs pre-built kernel (this) | Downloads from CachyOS mirrors, needs mirror version alignment |
| `gentoo-kernel-bin` | Reference implementation | Architectural model for how -bin ebuilds work |

### Architecture

```
Downloads:
1. CachyOS pre-patched source tarball       (for modules_prepare only)
   -> https://github.com/CachyOS/linux/releases/download/cachyos-{VER}-{PR}/...
2. CachyOS prebuilt kernel .pkg.tar.zst     (vmlinuz + modules)
   -> https://mirror.cachyos.org/repo/x86_64_v3/cachyos-v3/linux-cachyos[-variant][-lto]-{VER}-{PR}-x86_64_v3.pkg.tar.zst
3. CachyOS prebuilt headers .pkg.tar.zst    (.config, System.map, build scripts)
   -> same mirror, with -headers- in the name

Install flow:
src_unpack    -> extract source tarball + binary packages
src_prepare   -> set localversion files on source tree to match binary
src_configure -> copy .config from binary, run modules_prepare on source
src_install   -> install kernel image, modules, prepared source tree
pkg_preinst   -> kernel-install fixes symlinks
pkg_postinst  -> kernel-install runs depmod, generates initramfs, updates bootloader
```

## Adding a New Version

### Step 1: Check which versions are available on CachyOS mirrors

The CachyOS mirrors may have DIFFERENT versions per architecture repo.
Always verify before creating an ebuild.

```bash
# Check x86_64_v3 (primary repo, usually most up-to-date)
curl -s https://mirror.cachyos.org/repo/x86_64_v3/cachyos-v3/ | \
  grep -oP 'linux-cachyos-\d+\.\d+\.\d+-\d+-x86_64_v3\.pkg\.tar\.zst' | sort -uV

# Check x86_64_v4
curl -s https://mirror.cachyos.org/repo/x86_64_v4/cachyos-v4/ | \
  grep -oP 'linux-cachyos-\d+\.\d+\.\d+-\d+-x86_64_v4\.pkg\.tar\.zst' | sort -uV

# Check x86_64 baseline
curl -s https://mirror.cachyos.org/repo/x86_64/cachyos/ | \
  grep -oP 'linux-cachyos-\d+\.\d+\.\d+-\d+-x86_64\.pkg\.tar\.zst' | sort -uV
```

### Step 2: Verify corresponding cachyos-sources version exists

The ebuild PV must match an existing `cachyos-sources` version (they share
the same CachyOS source tarball).

```bash
# Check available cachyos-sources versions
ls sys-kernel/cachyos-sources/cachyos-sources-*.ebuild | sort -V | tail -5

# The CachyOS source tarball URL uses the same version+pkgrel:
# https://github.com/CachyOS/linux/releases/download/cachyos-{PV}-{CACHYOS_PR}/...
# CACHYOS_PR = PR + 1 (Gentoo -r0 -> pkgrel 1, -r1 -> pkgrel 2)
```

### Step 3: List available scheduler variants for the target version

```bash
VERSION="6.19.10"
PKGREL="1"
curl -s https://mirror.cachyos.org/repo/x86_64_v3/cachyos-v3/ | \
  grep -oP "linux-cachyos[^\"]*-${VERSION}-${PKGREL}-x86_64_v3\.pkg\.tar\.zst" | \
  grep -v '\.sig$' | sort -u
```

If a scheduler variant is NOT available for this version (e.g., bmq is at a
different version), remove it from the ebuild's IUSE, REQUIRED_USE, and SRC_URI.

### Step 4: Cross-reference genpatches version (informational)

The genpatches version is only needed for `cachyos-kernel` (source build).
The `-bin` ebuild does NOT apply genpatches. However, for version tracking:

```bash
# Genpatches version in cachyos-sources
grep 'K_GENPATCHES_VER=' sys-kernel/cachyos-sources/cachyos-sources-<VERSION>.ebuild

# Genpatches patchset in gentoo-kernel-bin (architectural reference)
grep 'PATCHSET=' /var/db/repos/gentoo/sys-kernel/gentoo-kernel-bin/gentoo-kernel-bin-<VERSION>.ebuild
```

### Step 5: Create the new ebuild

```bash
# Copy from latest existing version
OLD_VER=$(ls sys-kernel/cachyos-kernel-bin/cachyos-kernel-bin-*.ebuild | sort -V | tail -1)
cp "${OLD_VER}" sys-kernel/cachyos-kernel-bin/cachyos-kernel-bin-<NEW_VERSION>.ebuild
```

**Variables to review (most are auto-computed from PV/PR, no change needed):**

| Variable | Auto-computed? | When to update |
|----------|---------------|----------------|
| `CACHYOS_PR` | Yes (from PR) | Never - auto from revision |
| `MY_P` | Yes (from PV+PR) | Never |
| `BINPKG_VER` | Yes (from PV+PR) | Never |
| `MIRROR_V3` | No | Only if mirror URL changes |
| `IUSE` schedulers | No | Add/remove based on mirror availability (Step 3) |
| `REQUIRED_USE` | No | Must match IUSE scheduler flags |
| `SRC_URI` blocks | No | Add/remove blocks for available variants |

### Step 6: Update SRC_URI for available variants

When adding/removing scheduler variants, update these sections in sync:

1. **IUSE** — add/remove scheduler flags (e.g., `bmq`)
2. **REQUIRED_USE** — update `^^ ( bore eevdf ... )` constraint
3. **SRC_URI** — add/remove the download blocks for each variant
4. **`_cachyos_variant_suffix()`** — add/remove variant cases
5. **`_cachyos_bin_distfile()`** — add/remove variant cases
6. **`_cachyos_headers_distfile()`** — add/remove variant cases

### Step 7: Generate Manifest

```bash
ebuild sys-kernel/cachyos-kernel-bin/cachyos-kernel-bin-<VERSION>.ebuild manifest
# Or with sudo:
sudo ebuild sys-kernel/cachyos-kernel-bin/cachyos-kernel-bin-<VERSION>.ebuild manifest
```

**Note:** This downloads ALL distfiles for ALL USE flag combinations.
Total download can be >2GB. Ensure good connectivity.

### Step 8: Test (see Testing section below)

## Version Mapping Reference

### CachyOS package name -> ebuild USE flag mapping

| USE flags | CachyOS package name | Kernel release string |
|-----------|---------------------|-----------------------|
| `bore lto` | `linux-cachyos` (default) | `{PV}-{PR}-cachyos` |
| `bore !lto !gcc` | `linux-cachyos-bore` | `{PV}-{PR}-cachyos-bore` |
| `bore gcc` | `linux-cachyos-gcc` | `{PV}-{PR}-cachyos-gcc` |
| `eevdf lto` | `linux-cachyos-eevdf-lto` | `{PV}-{PR}-cachyos-eevdf-lto` |
| `eevdf !lto` | `linux-cachyos-eevdf` | `{PV}-{PR}-cachyos-eevdf` |
| `hardened lto` | `linux-cachyos-hardened-lto` | `{PV}-{PR}-cachyos-hardened-lto` |
| `hardened !lto` | `linux-cachyos-hardened` | `{PV}-{PR}-cachyos-hardened` |
| `rt-bore lto` | `linux-cachyos-rt-bore-lto` | `{PV}-{PR}-cachyos-rt-bore-lto` |
| `rt-bore !lto` | `linux-cachyos-rt-bore` | `{PV}-{PR}-cachyos-rt-bore` |
| `deckify lto` | `linux-cachyos-deckify-lto` | `{PV}-{PR}-cachyos-deckify-lto` |
| `deckify !lto` | `linux-cachyos-deckify` | `{PV}-{PR}-cachyos-deckify` |
| `server lto` | `linux-cachyos-server-lto` | `{PV}-{PR}-cachyos-server-lto` |
| `server !lto` | `linux-cachyos-server` | `{PV}-{PR}-cachyos-server` |
| `lts` | `linux-cachyos-lts` | `{PV}-{PR}-cachyos-lts` |

### Kernel release string derivation

CachyOS PKGBUILD sets localversion files:
```
localversion.10-pkgrel = "-{pkgrel}"            (e.g., "-1")
localversion.20-pkgname = "-{variant_suffix}"    (e.g., "-cachyos" or "-cachyos-bore")
```

Full kernel release: `{PV}-{pkgrel}-{variant_suffix}`
Example: `6.19.10-1-cachyos` or `6.19.10-1-cachyos-bore`

The `_cachyos_variant_suffix()` function in the ebuild must produce a suffix
that exactly matches the module directory name in the binary package.

### Revision bumps

- Gentoo `-r0` (default) -> CachyOS pkgrel `1`
- Gentoo `-r1` -> CachyOS pkgrel `2`
- Formula: `CACHYOS_PR = $((${PR#r} + 1))`

No variable changes needed. Just copy the ebuild with new revision.

### Mirror URL structure

```
https://mirror.cachyos.org/repo/
  x86_64/cachyos/           <- baseline x86-64 packages
  x86_64_v3/cachyos-v3/     <- x86-64-v3 optimized (AVX2+, recommended)
  x86_64_v4/cachyos-v4/     <- x86-64-v4 optimized (AVX-512)
```

## Testing

### Quick validation (no download needed)

```bash
# Verify ebuild syntax
pkgcheck scan sys-kernel/cachyos-kernel-bin

# Check dependency resolution
emerge --pretend --verbose =sys-kernel/cachyos-kernel-bin-<VERSION>

# Test with non-default USE flags
USE="eevdf -bore lto" emerge --pretend --verbose =sys-kernel/cachyos-kernel-bin-<VERSION>
USE="hardened -bore -lto" emerge --pretend --verbose =sys-kernel/cachyos-kernel-bin-<VERSION>
```

### Download and unpack test

```bash
# Generate manifest (downloads distfiles)
ebuild sys-kernel/cachyos-kernel-bin/cachyos-kernel-bin-<VERSION>.ebuild manifest

# Test unpack phase
ebuild sys-kernel/cachyos-kernel-bin/cachyos-kernel-bin-<VERSION>.ebuild clean unpack

# Test through configure phase (includes modules_prepare)
ebuild sys-kernel/cachyos-kernel-bin/cachyos-kernel-bin-<VERSION>.ebuild clean configure
```

### Full install test

```bash
# Full install
sudo emerge --ask =sys-kernel/cachyos-kernel-bin-<VERSION>

# Verify installation
ls /usr/src/linux-*/dist-kernel
ls /lib/modules/*/kernel/ | head -5
```

### Post-install verification

```bash
# Check kernel is installed
cat /usr/src/linux-*/dist-kernel

# Check modules
ls /lib/modules/

# Check initramfs was generated
ls /boot/initramfs-*

# Boot the kernel and verify
uname -r  # Should show: {PV}-{PR}-cachyos[-variant]
```

### CI test matrix (for .github/workflows/)

Since -bin ebuilds don't compile the kernel, CI tests are fast (minutes):

```yaml
test_matrix:
  - ""                           # default: bore + lto
  - "bore -lto -gcc"             # bore without LTO
  - "gcc -lto"                   # GCC variant
  - "eevdf -bore lto"            # EEVDF + LTO
  - "eevdf -bore -lto"           # EEVDF without LTO
  - "hardened -bore lto"         # hardened + LTO
  - "rt-bore -bore lto"          # RT-BORE + LTO
  - "deckify -bore lto"          # deckify + LTO
  - "server -bore lto"           # server + LTO
```

## Troubleshooting

### Binary package not found on mirror (HTTP 404)

CachyOS mirrors update asynchronously. A version may exist on x86_64_v3
but not yet on x86_64_v4. Solutions:
- Wait for the mirror to sync
- Only include architectures with confirmed packages in SRC_URI
- Check alternative mirrors: `https://archive.cachyos.org/`

### KV_FULL mismatch / wrong module directory

The `_cachyos_variant_suffix()` must produce a suffix that matches the kernel
release string inside the binary package. To verify:

```bash
# Extract and check the module directory name
tar tf /var/cache/distfiles/linux-cachyos-*.pkg.tar.zst | grep 'usr/lib/modules/' | head -1
# Example output: usr/lib/modules/6.19.10-1-cachyos/
# The "6.19.10-1-cachyos" part must match KV_FULL
```

If there's a mismatch, the `src_configure` phase has auto-detection that will
warn and adjust. But fixing `_cachyos_variant_suffix()` is the proper solution.

### modules_prepare fails

- For LTO kernels: ensure `llvm-core/clang`, `llvm-core/lld` are installed
- The .config from the binary must be compatible with the source tree version
- Check that `CACHYOS_PR` matches: source tarball version must equal binary version

### Pacman metadata files (.PKGINFO, .MTREE)

CachyOS `.pkg.tar.zst` files contain pacman metadata at the archive root.
These are harmlessly extracted during `src_unpack`. The `src_install` function
only copies specific paths, ignoring these files.

## Quick Reference: File Locations

```
sys-kernel/cachyos-kernel-bin/
  AGENT.md                                  # This file
  cachyos-kernel-bin-<VER>.ebuild           # The binary kernel ebuild
  metadata.xml                              # Package metadata and USE flags
  Manifest                                  # Checksums for all distfiles

# Version sync sources:
sys-kernel/cachyos-sources/cachyos-sources-<VER>.ebuild   # K_GENPATCHES_VER, ZFS_COMMIT, CACHYOS_PR

# Reference ebuild:
/var/db/repos/gentoo/sys-kernel/gentoo-kernel-bin/        # Architectural reference for -bin ebuilds

# CachyOS mirrors:
https://mirror.cachyos.org/repo/x86_64_v3/cachyos-v3/    # Primary binary source (x86-64-v3)
https://mirror.cachyos.org/repo/x86_64_v4/cachyos-v4/    # v4 binaries
https://mirror.cachyos.org/repo/x86_64/cachyos/           # Baseline binaries

# CachyOS upstream:
https://github.com/CachyOS/linux/releases                 # Pre-patched source tarballs
https://github.com/CachyOS/linux-cachyos                  # PKGBUILDs (naming reference)
```
