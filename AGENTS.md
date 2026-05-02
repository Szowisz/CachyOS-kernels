# CachyOS-kernels AGENTS.md

> **Repo**: Gentoo overlay for CachyOS kernel ebuilds (sources, dist-kernel, binary, virtuals)
> **Upstream**: https://github.com/CachyOS/linux-cachyos

---

## Before Starting Any Work

```bash
# Warm up keys (avoids interactive password prompts later)
ssh-add -l          # verify SSH agent loaded
gpg --sign --armor --local-user <KEYID> -o /dev/null <<<"warmup"
ssh -T git@github.com   # warm SSH connection
```

---

## Package Architecture

```
sys-kernel/
  cachyos-sources/       # kernel-2.eclass — only installs source, no build
  cachyos-kernel/        # kernel-build.eclass — builds & installs full kernel
    files -> ../cachyos-sources/files   # SYMLINK: shares patches/configs
  cachyos-kernel-bin/    # kernel-install.eclass — downloads pre-built binaries
virtual/
  dist-kernel/           # virtual to resolve dist-kernel providers
  cachyos-sources/       # virtual for cachyos kernel source
  linux-sources/         # virtual for linux kernel source
```

**Critical**: `cachyos-kernel/files` is a symlink to `cachyos-sources/files`. All version-specific patches and configs are shared.

---

## Version Update Trigger

**Only follow upstream `linux-cachyos` commits**, NOT kernel.org releases.

Upstream commit page: https://github.com/CachyOS/linux-cachyos/commits/

Each commit message describes which versions were bumped, e.g.:
- `7.0.3-1 && 6.18.26-1` → create ebuilds for 7.0.3 and 6.18.26 only
- `6.19.12-1 && 6.18.22-1` → create ebuilds for 6.19.12 and 6.18.22 only

Do NOT auto-generate ebuilds for other kernel.org versions (6.12, 6.6, etc.) just because they exist on kernel.org.

---

## Step-by-Step Update Workflow

### 1. cachyos-sources (always first)

```bash
# Auto-detect latest kernel version and create new ebuild:
python3 ./sys-kernel/cachyos-sources/script/update_ebuild.py

# For LTS versions, specify --lts and --version:
python3 ./sys-kernel/cachyos-sources/script/update_ebuild.py --lts --version 6.18.26

# For specific version override:
python3 ./sys-kernel/cachyos-sources/script/update_ebuild.py --version 7.0.3
```

The script does:
- Creates ebuild from latest template
- Fetches upstream config versions for USE flag availability
- Runs `get_files.py` (clones kernel-patches + linux-cachyos for patches/configs)
- Updates commit hash and manifest

**Manually verify after script runs:**
- `K_GENPATCHES_VER` aligns with official `gentoo-sources` (see Genpatches section below)
- The last-line commit hash matches the `commit` file in `files/<VERSION>/commit`

### 2. cachyos-kernel

```bash
# Copy from latest kernel ebuild
cp cachyos-kernel-<OLD_VER>.ebuild cachyos-kernel-<NEW_VER>.ebuild

# Update these values from cachyos-sources:
#   GENPATCHES_VER  ←  K_GENPATCHES_VER (from sources ebuild)
#   ZFS_COMMIT      ←  ZFS_COMMIT (from sources ebuild)
#   last line hash  ←  last line hash (from sources ebuild)
#   PDEPEND         ←  auto: >=virtual/dist-kernel-${PV}

# Generate manifest
ebuild sys-kernel/cachyos-kernel/cachyos-kernel-<VERSION>.ebuild manifest

# Test (unpack + prepare only, NO build):
sudo ebuild sys-kernel/cachyos-kernel/cachyos-kernel-<VERSION>.ebuild clean prepare
```

**Important**: The kernel ebuild may reference shared patch directories like `${FILESDIR}/6.19.0/misc/0002-fix-autofdo-propeller-lto-thin-dist.patch`. Ensure these shared patch dirs exist in `cachyos-sources/files/` (the symlink resolves them).

### 3. cachyos-kernel-bin

**Bin kernel tracks both the latest mainline kernel AND the latest LTS kernel** (if upstream provides one). Old bin ebuilds that are neither the latest mainline nor the latest LTS should be removed.

**When updating a bin ebuild, always `mv` the old ebuild to the new version first, then edit it.** Do NOT `cp` and keep the old ebuild around — upstream stops hosting old binaries, so running `ebuild manifest` on the old version will fail because the distfiles are no longer downloadable. Renaming instead of copying avoids this problem.

For each new version, the bin packages may have DIFFERENT scheduler variant availability on CachyOS mirrors. Always check:
```bash
curl -s https://mirror.cachyos.org/repo/x86_64_v3/cachyos-v3/ | \
  grep -oP "linux-cachyos[^\"]*-${VERSION}-${PKGREL}-x86_64_v3\.pkg\.tar\.zst" | sort -u
```

The USE flags must match exactly what's available on the mirror. If a variant (e.g., `hardened`, `deckify`) doesn't exist for this version, remove it from IUSE/REQUIRED_USE/SRC_URI.

### 3a. cachyos-kernel-bin Variant Coverage Rules

**Core principle: the ebuild MUST cover every upstream bin variant available on the mirror.**

Every time a new bin ebuild is created, check all available packages on the CachyOS mirror:
```bash
curl -s https://mirror.cachyos.org/repo/x86_64_v3/cachyos-v3/ | \
  grep -oP "linux-cachyos[^\"]*-${VERSION}-${PKGREL}-x86_64_v3\.pkg\.tar\.zst" | sort -u
```

IUSE / REQUIRED_USE / SRC_URI must precisely cover all combinations on the mirror. If a variant (e.g., `hardened`, `deckify`) doesn't exist for this version, remove it from the ebuild. Conversely, if it exists, it MUST be added.

**LTO / GCC USE flags follow the same principle:** only provide `lto` or `gcc` USE when the mirror has the corresponding packages. For example, 6.18.26 LTS only has `linux-cachyos-lts` (no lto variant), so the ebuild does not need an `lto` USE.

**Variant selection uses `^^ ( ... )` mutual exclusion:** even when only one variant option exists for a version (e.g., hardened-only or lts-only), use this pattern for structural consistency.

Typical IUSE per version:

| Version | Mirror variants | IUSE | REQUIRED_USE |
|---------|----------------|------|-------------|
| Mainline (7.x) | bore, eevdf, rt-bore, server, deckify (+ bore's gcc sub-variant), each with lto/non-lto | `bore +eevdf rt-bore server deckify +lto gcc debug` | `^^ ( bore eevdf rt-bore server deckify ) ?? ( lto gcc ) gcc? ( bore )` |
| 6.19.x (hardened-only) | hardened + hardened-lto | `hardened lto debug` | `hardened` |
| 6.18.x (LTS) | lts (single package, no lto) | `lts debug` | `lts` |

**Variant → package name mapping reference:** see `sys-kernel/cachyos-kernel-bin/AGENT.md`.

**Checklist for new bin ebuilds:**
1. Check mirror for all available variants and their lto/non-lto combinations
2. Set IUSE to cover all available variants + `lto` (if available) + `gcc` (if available) + `debug`
3. Ensure REQUIRED_USE `^^ ( ... )` includes all variant options
4. Update `_cachyos_variant_suffix()`, `_cachyos_bin_distfile()`, `_cachyos_headers_distfile()` functions
5. Compare against the previous ebuild: confirm no missing variants, and remove variants not on the mirror

### 4. virtual/dist-kernel

```bash
cp virtual/dist-kernel/dist-kernel-<OLD_VER>.ebuild virtual/dist-kernel/dist-kernel-<NEW_VER>.ebuild
ebuild virtual/dist-kernel/dist-kernel-<VERSION>.ebuild manifest
```

The virtual simply depends on `>=sys-kernel/cachyos-sources-${PV}` for source packages and `>=sys-kernel/cachyos-kernel-${PV}` through the dist-kernel eclass.

---

## Genpatches Version Alignment

**The genpatches version MUST match the official Gentoo `gentoo-sources` package.**

The auto-generated version from `update_ebuild.py` can be WRONG (especially for LTS). Always verify:

```bash
# Check the official version:
grep 'K_GENPATCHES_VER' /var/db/repos/gentoo/sys-kernel/gentoo-sources/gentoo-sources-<VERSION>.ebuild

# Fix if needed:
sed -i 's/K_GENPATCHES_VER="<wrong>"/K_GENPATCHES_VER="<correct>"/' cachyos-sources-<VERSION>.ebuild
```

For `cachyos-kernel`, cross-reference with `gentoo-kernel`:
```bash
grep 'PATCHSET' /var/db/repos/gentoo/sys-kernel/gentoo-kernel/gentoo-kernel-<VERSION>.ebuild
```

---

## Cleanup Rules

**Delete ebuilds whose version does NOT exist in the corresponding official Gentoo package:**

| Our package | Reference package |
|-------------|------------------|
| `cachyos-sources` | `/var/db/repos/gentoo/sys-kernel/gentoo-sources/` |
| `cachyos-kernel` | `/var/db/repos/gentoo/sys-kernel/gentoo-kernel/` |
| `cachyos-kernel-bin` | Keep latest mainline + latest LTS (if upstream has one) |
| `virtual/dist-kernel` | Align with kernel cleanup |

Match by kernel version (ignore `-rN` revision suffix):
```bash
# Example: check if version should exist
ls /var/db/repos/gentoo/sys-kernel/gentoo-sources/gentoo-sources-<VER>.ebuild 2>/dev/null
```

When deleting:
1. Remove the `.ebuild` file
2. Remove `files/<VERSION>/` directory (if not shared)
3. Remove `files/<VERSION>-rN/` directories (for revision-specific files)
4. **Do NOT remove shared patch directories** like `files/6.19.0/`, `files/6.18.10/`
5. Regenerate Manifest: `ebuild <latest.ebuild> manifest`

---

## Git Commit Convention

Use `pkgdev commit --signoff` for all commits. Split into two commits:

### Commit 1: Version update
```bash
# Stage all new/modified files (ebuilds, files dirs, manifests, virtual/dist-kernel, AGENTS.md)
git add -v sys-kernel/cachyos-sources/ sys-kernel/cachyos-kernel/ sys-kernel/cachyos-kernel-bin/
git add -v virtual/dist-kernel/ AGENTS.md

# Format: sys-kernel: update CachyOS kernels to <V1>, <V2> and <V3> (<bin>)
pkgdev commit --signoff -m "sys-kernel: update CachyOS kernels to <VERSION1>, <VERSION2> and <VERSION3> (bin)"
```

### Commit 2: Cleanup
```bash
# Stage deleted files (git auto-stages deletions, just commit)
# Format: sys-kernel: drop old versions, <range1>, <range2>, ...
pkgdev commit --signoff -m "sys-kernel: drop old versions, <deleted version ranges>"
```

**Message format** follows existing convention, e.g.:
- `sys-kernel: update CachyOS kernels to 6.18.26, 7.0.3`
- `sys-kernel: update CachyOS kernels to 6.18.25, 7.0.2 and 7.0.1 (bin)`
- `sys-kernel: drop old versions, 6.6.64-72, 6.19.0-10, ...`

---

## Testing

### cachyos-sources (full test):
```bash
sudo ebuild sys-kernel/cachyos-sources/cachyos-sources-<VER>.ebuild clean package
```

### cachyos-kernel (prepare only, NEVER build):
```bash
sudo ebuild sys-kernel/cachyos-kernel/cachyos-kernel-<VER>.ebuild clean prepare
```

### cachyos-kernel-bin (unpack only):
```bash
sudo ebuild sys-kernel/cachyos-kernel-bin/cachyos-kernel-bin-<VER>.ebuild clean unpack
```

### virtual/dist-kernel (manifest check only):
```bash
ebuild virtual/dist-kernel/dist-kernel-<VER>.ebuild manifest
```

---

## Commit

After all tests pass and manifests are regenerated:

```bash
# First commit: version update (add new ebuilds, files, manifests, virtual, AGENTS.md)
git add -v sys-kernel/cachyos-sources/ sys-kernel/cachyos-kernel/
git add -v virtual/dist-kernel/ AGENTS.md
pkgdev commit --signoff -m "sys-kernel: update CachyOS kernels to <V1>, <V2> and <V3>"

# Second commit: cleanup old versions (removed ebuilds, files dirs, manifests)
pkgdev commit --signoff -m "sys-kernel: drop old versions, <deleted ranges>"
```

### Bin kernel commit (single atomic commit)

**Bin kernel updates must be in a single commit** that includes both adding new ebuilds and removing old ones. This is because `ebuild manifest` on an old bin version will fail once upstream stops hosting those binaries, making separate add/drop commits break bisection and reproducibility.

```bash
# Single commit: add new bin ebuilds + remove old bin ebuilds + regenerate Manifest
git add -v sys-kernel/cachyos-kernel-bin/
pkgdev commit --signoff -m "sys-kernel: update CachyOS kernels to <V1>, <V2> and <V3> (bin)"
```

---

## USE Flags

### Version-dependent USE flags

Some USE flags only exist for certain kernel versions. The `update_ebuild.py` script handles this automatically by checking upstream PKGBUILD configs (`.SRCINFO`):

- `hardened`: Not available for 7.0.x series → removed from IUSE/REQUIRED_USE/src_prepare
- `bmq`: Available for LTS series (6.6.x) but not older versions

When manually creating kernel ebuilds, sync USE flag changes from the corresponding `cachyos-sources` ebuild.

### Bin kernel USE flags

For `cachyos-kernel-bin`, USE flags must reflect the exact combinations available on CachyOS mirrors. Each scheduler variant (`bore`, `eevdf`, `hardened`, `deckify`, `rt-bore`) may or may not have LTO/non-LTO/GCC variants available at a given version.

---

## Common Pitfalls

1. **Don't blindly update all kernel.org versions** — only follow upstream linux-cachyos commits
2. **Genpatches version from the script may be wrong** for LTS — always verify against gentoo-sources
3. **Shared patch directories** (`files/6.19.0/`, `files/6.18.10/`) are version-independent — don't delete during cleanup
4. **cachyos-kernel/files is a symlink** to cachyos-sources/files — changes to one affect both
5. **cachyos-kernel-bin keeps latest mainline + latest LTS (and any hardened-only version)** — remove old bin ebuilds that are neither. Every upstream bin variant must be covered by the ebuild's USE flags; if the mirror lacks an lto variant, omit the `lto` USE
6. **Manifest must be regenerated** after adding/removing any ebuild
7. **`ebuild ... manifest` may need sudo** for binpkgs directory access

---

## File Reference

```
sys-kernel/cachyos-sources/
  script/update_ebuild.py    # main update script
  script/get_files.py        # fetches patches & configs from upstream repos

sys-kernel/cachyos-kernel/
  files -> ../cachyos-sources/files   # SYMLINK

sys-kernel/cachyos-kernel-bin/
  AGENT.md                    # detailed bin kernel guide

Upstream:
  https://github.com/CachyOS/linux-cachyos/commits/    # version bump trigger
  https://github.com/CachyOS/linux/releases             # pre-patched tarballs
  https://github.com/CachyOS/kernel-patches             # patch source
  https://mirror.cachyos.org/repo/                      # binary packages

Reference (read-only):
  /var/db/repos/gentoo/sys-kernel/gentoo-sources/       # genpatches alignment
  /var/db/repos/gentoo/sys-kernel/gentoo-kernel/        # kernel genpatches cross-ref
  /var/db/repos/gentoo/sys-kernel/gentoo-kernel-bin/    # bin kernel reference
```
