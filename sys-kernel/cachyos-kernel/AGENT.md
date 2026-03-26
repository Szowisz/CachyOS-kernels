# cachyos-kernel Maintenance Guide for AI Agents

This document describes how to maintain `sys-kernel/cachyos-kernel` ebuilds,
including adding new versions, syncing with `cachyos-sources`, and testing.

## Overview

`cachyos-kernel` is a **Distribution Kernel** (dist-kernel) that inherits
`kernel-build.eclass`. Unlike `cachyos-sources` (which only installs kernel
sources), `cachyos-kernel` **builds and installs** the complete kernel
automatically when emerged.

### Relationship to cachyos-sources

- `cachyos-kernel` and `cachyos-sources` share the same `files/` directory
  (via symlink: `files -> ../cachyos-sources/files`)
- Both use the same CachyOS pre-patched tarball, genpatches, patches, and configs
- `cachyos-kernel` must always be version-synchronized with `cachyos-sources`
- The key difference is the eclass: `kernel-2` vs `kernel-build`

## Adding a New Version

### Step 1: Verify cachyos-sources exists

A new `cachyos-kernel` version should only be created when a corresponding
`cachyos-sources` version already exists with its `files/` directory populated.

```bash
# Check available cachyos-sources versions
ls sys-kernel/cachyos-sources/cachyos-sources-*.ebuild | sort -V

# Verify the files directory exists for the target version
ls sys-kernel/cachyos-sources/files/<VERSION>/
# Must contain: config-bore, config-bmq, config-eevdf, config-rt-bore,
#               config-hardened, config-deckify, sched/, misc/
```

### Step 2: Identify version-specific variables to sync

Read the cachyos-sources ebuild for the target version and extract:

```bash
# From sys-kernel/cachyos-sources/cachyos-sources-<VERSION>.ebuild:
grep 'K_GENPATCHES_VER='    sys-kernel/cachyos-sources/cachyos-sources-<VERSION>.ebuild
grep 'ZFS_COMMIT='          sys-kernel/cachyos-sources/cachyos-sources-<VERSION>.ebuild
grep '^# [0-9a-f]\{40\}'   sys-kernel/cachyos-sources/cachyos-sources-<VERSION>.ebuild  # CachyOS commit hash (last line)
```

Also cross-reference the genpatches version with gentoo-kernel:

```bash
# From /var/db/repos/gentoo/sys-kernel/gentoo-kernel/gentoo-kernel-<VERSION>.ebuild:
grep 'PATCHSET=' /var/db/repos/gentoo/sys-kernel/gentoo-kernel/gentoo-kernel-<VERSION>.ebuild
# Example: PATCHSET=linux-gentoo-patches-6.19.6
# The genpatches version (K_GENPATCHES_VER) should be >= the number after the last dot
```

### Step 3: Create the new ebuild

Copy the latest cachyos-kernel ebuild and update version-specific values:

```bash
cp sys-kernel/cachyos-kernel/cachyos-kernel-<OLD_VERSION>.ebuild \
   sys-kernel/cachyos-kernel/cachyos-kernel-<NEW_VERSION>.ebuild
```

**Variables to update in the new ebuild:**

| Variable | Source | Description |
|----------|--------|-------------|
| `GENPATCHES_VER` | `K_GENPATCHES_VER` in cachyos-sources | Genpatches version number |
| `ZFS_COMMIT` | `ZFS_COMMIT` in cachyos-sources | ZFS git commit hash |
| Last line comment | Last line in cachyos-sources | CachyOS upstream commit hash |

**Version-specific patches to check:**

The `files_dir` variable is set to `${FILESDIR}/${PVR}` which resolves to
`files/<VERSION>` (through the symlink). Verify that:

1. The `AutoFDO/Propeller LTO fix` patch path is correct:
   ```bash
   # Current: ${FILESDIR}/6.19.0/misc/0002-fix-autofdo-propeller-lto-thin-dist.patch
   # Check if this patch still applies to the new version, or if a new version-specific
   # patch exists under files/<NEW_VERSION>/misc/
   ```

2. All scheduler patches exist in `files/<VERSION>/sched/`:
   - `0001-bore-cachy.patch`
   - `0001-prjc-cachy.patch` (for BMQ)

3. All misc patches exist in `files/<VERSION>/misc/`:
   - `0001-rt-i915.patch` (for RT)
   - `0001-hardened.patch` (for hardened)
   - `dkms-clang.patch` (for LTO/KCFI)

4. All config files exist in `files/<VERSION>/`:
   - `config-bore`, `config-bmq`, `config-eevdf`
   - `config-rt-bore`, `config-hardened`, `config-deckify`

### Step 4: Check for ebuild logic changes

Compare the new cachyos-sources with the previous version to detect structural
changes (new USE flags, changed patch application order, new config options):

```bash
diff sys-kernel/cachyos-sources/cachyos-sources-<OLD_VERSION>.ebuild \
     sys-kernel/cachyos-sources/cachyos-sources-<NEW_VERSION>.ebuild
```

Common changes to port:
- New/removed USE flags (update IUSE, REQUIRED_USE, and corresponding config logic)
- New patch files (add eapply calls)
- Changed config options (update scripts/config calls)
- Changed genpatches exclusions (update genpatch_exclude logic)

### Step 5: Update virtual/dist-kernel

If a new kernel **minor** version is added (e.g., 6.20.x when only 6.19.x existed):

```bash
cp virtual/dist-kernel/dist-kernel-<OLD_VERSION>.ebuild \
   virtual/dist-kernel/dist-kernel-<NEW_VERSION>.ebuild
```

For **patch** version bumps within the same minor (e.g., 6.19.10 -> 6.19.11),
still create the virtual to ensure the version exists.

### Step 6: Generate Manifest

```bash
# Generate manifest with checksums for all distfiles
cd /path/to/overlay
ebuild sys-kernel/cachyos-kernel/cachyos-kernel-<VERSION>.ebuild manifest

# Also update virtual manifest if changed
ebuild virtual/dist-kernel/dist-kernel-<VERSION>.ebuild manifest
```

### Step 7: Test the ebuild

See "Testing" section below.

## Syncing Genpatches Version

The genpatches version (`GENPATCHES_VER`) must be synchronized with
`cachyos-sources` which in turn tracks the Gentoo genpatches releases.

### How genpatches versioning works

- Genpatches are released as: `genpatches-<MAJOR>.<MINOR>-<VER>.<type>.tar.xz`
- Example: `genpatches-6.19-9.base.tar.xz`, `genpatches-6.19-9.extras.tar.xz`
- `<VER>` is `K_GENPATCHES_VER` in cachyos-sources / `GENPATCHES_VER` in cachyos-kernel
- The version number increments independently for each kernel minor series
- Hosted at: `https://dev.gentoo.org/~alicef/dist/genpatches/`

### When to update genpatches

Update when `cachyos-sources` updates its `K_GENPATCHES_VER`:

```bash
# Check current genpatches version in cachyos-sources
grep K_GENPATCHES_VER sys-kernel/cachyos-sources/cachyos-sources-<VERSION>.ebuild

# Check what gentoo-kernel uses (for cross-reference only)
grep PATCHSET /var/db/repos/gentoo/sys-kernel/gentoo-kernel/gentoo-kernel-<VERSION>.ebuild
```

### Update procedure

1. Update `GENPATCHES_VER=<NEW_VER>` in the cachyos-kernel ebuild
2. Re-run `ebuild ... manifest` to update checksums
3. Verify the new genpatches tarball is available:
   ```bash
   wget -q --spider "https://dev.gentoo.org/~alicef/dist/genpatches/genpatches-6.19-<NEW_VER>.base.tar.xz" && echo OK
   ```

### Genpatches exclusion rules

Some genpatches conflict with CachyOS patches. These exclusions are
version-specific and must be verified for each new genpatches release:

| Exclude Pattern | Condition | Reason |
|-----------------|-----------|--------|
| `10*` (1000-1099) | Always | Kernel upgrade patches; CachyOS tarball is already at correct version |
| `1810*` | `USE=bmq` | Scheduler proxy yield patch conflicts with BMQ's do_sched_yield() |
| `1510*` | `USE=hardened` | FS link security defaults conflict with hardened's stricter values |
| `4567*` | `USE=hardened` | Gentoo Kconfig additions break hardened's DEFAULT_MMAP_MIN_ADDR hunk |

When updating genpatches, check if new patches have been added that might
conflict with CachyOS schedulers or the hardened patchset:

```bash
# List all patches in the new genpatches
tar tf /var/cache/distfiles/genpatches-6.19-<VER>.base.tar.xz
tar tf /var/cache/distfiles/genpatches-6.19-<VER>.extras.tar.xz
```

## Version Number Reference

### Major version bump (e.g., 6.19 -> 6.20)

When a new kernel minor version series starts:

1. `GENPATCHES_VER` resets (usually starts at a low number for the new series)
2. The `AutoFDO/Propeller fix` patch path may change:
   - Check if `files/<NEW_SERIES>.0/misc/0002-fix-autofdo-propeller-lto-thin-dist.patch` exists
   - Or if the fix was upstreamed and the patch is no longer needed
3. Check if new USE flags were added/removed in cachyos-sources
4. The `files/` symlink automatically picks up new version directories

### Patch version bump (e.g., 6.19.9 -> 6.19.10)

Usually only requires:
1. Copy ebuild with new version number
2. Sync `GENPATCHES_VER` if changed
3. Sync `ZFS_COMMIT` if changed
4. Sync CachyOS commit hash (last line comment)
5. Verify files directory exists: `files/<NEW_VERSION>/`
6. Run manifest

### Revision bump (e.g., 6.19.10 -> 6.19.10-r1)

The `CACHYOS_PR` variable automatically maps Gentoo revisions to CachyOS releases:
- `-r0` (no revision) -> CachyOS release 1 (`cachyos-6.19.10-1.tar.gz`)
- `-r1` -> CachyOS release 2 (`cachyos-6.19.10-2.tar.gz`)

Simply rename/copy the ebuild with the new revision. No variable changes needed
unless other content changed.

## Testing

### Quick syntax check

```bash
# Check ebuild syntax (no network access needed)
pkgcheck scan sys-kernel/cachyos-kernel
```

### Local emerge test (source preparation only)

```bash
# Test up to the prepare phase (downloads + patches, no compilation)
ebuild sys-kernel/cachyos-kernel/cachyos-kernel-<VERSION>.ebuild clean prepare

# Test with specific USE flags
USE="bore llvm-lto-thin clang" ebuild sys-kernel/cachyos-kernel/cachyos-kernel-<VERSION>.ebuild clean prepare
USE="bmq" ebuild sys-kernel/cachyos-kernel/cachyos-kernel-<VERSION>.ebuild clean prepare
USE="hardened" ebuild sys-kernel/cachyos-kernel/cachyos-kernel-<VERSION>.ebuild clean prepare
```

### Full build test

```bash
# Full build (takes 10-60+ minutes depending on hardware)
emerge --ask sys-kernel/cachyos-kernel

# Or with specific USE flags
USE="bore clang llvm-lto-thin" emerge --ask sys-kernel/cachyos-kernel
```

### CI test matrix (GitHub Actions)

The repository uses `.github/workflows/ebuild-test.yml` for automated testing.
Currently it tests `cachyos-sources` only. To add `cachyos-kernel` testing:

1. The CI workflow detects changed ebuilds via `git diff`
2. It tests various USE flag combinations in a Gentoo Docker container
3. For `cachyos-kernel`, the CI would need to test `emerge` (full build),
   which is significantly more resource-intensive than `cachyos-sources`
   (which only tests source preparation)

**Recommended CI test combinations for cachyos-kernel:**

| Test Name | USE Flags | What it validates |
|-----------|-----------|-------------------|
| default | (defaults) | BORE + LTO thin + O3 + BBR3 |
| gcc-no-lto | `bore -clang -llvm-lto-thin -autofdo -propeller` | GCC build without LTO |
| bmq | `bmq -bore -clang -llvm-lto-thin -autofdo -propeller` | BMQ scheduler |
| hardened | `hardened -bore clang llvm-lto-thin` | Hardened build |
| eevdf-minimal | `eevdf -bore -clang -llvm-lto-thin -autofdo -propeller -o3 -bbr3` | Minimal EEVDF build |
| portable | `bore mgeneric_v3 -mnative clang llvm-lto-thin` | Portable binary package |

## Quick Reference: File Locations

```
sys-kernel/cachyos-kernel/
├── AGENT.md                          # This file
├── cachyos-kernel-<VER>.ebuild       # The dist-kernel ebuild
├── files -> ../cachyos-sources/files # Symlink to shared patches/configs
├── metadata.xml                      # Package metadata and USE flag descriptions
└── Manifest                          # Checksums for all distfiles

sys-kernel/cachyos-sources/
├── cachyos-sources-<VER>.ebuild      # The kernel-sources ebuild (reference)
├── files/<VER>/                      # Per-version patches and configs
│   ├── config-bore                   # Config for BORE scheduler
│   ├── config-bmq                    # Config for BMQ scheduler
│   ├── config-eevdf                  # Config for EEVDF scheduler
│   ├── config-rt-bore                # Config for RT-BORE scheduler
│   ├── config-hardened               # Config for hardened
│   ├── config-deckify                # Config for Steam Deck
│   ├── sched/                        # Scheduler patches
│   ├── misc/                         # Misc patches (RT, hardened, dkms, etc.)
│   └── commit                        # CachyOS upstream commit hash
└── metadata.xml

virtual/dist-kernel/
├── dist-kernel-<VER>.ebuild          # Virtual for dist-kernel resolution
├── metadata.xml
└── Manifest

# Reference (read-only, from system repos):
/var/db/repos/gentoo/sys-kernel/gentoo-kernel/   # For genpatches cross-reference
/var/db/repos/gentoo/eclass/kernel-build.eclass  # The dist-kernel build eclass
```

## Troubleshooting

### "KV_FULL mismatch" or "Kernel version mismatch" during build

The `kernel-build.eclass` validates that the built kernel version matches the
ebuild PV. CachyOS sets `LOCALVERSION="-cachyos"` via `localversion.20-pkgname`,
and the ebuild sets `CONFIG_LOCALVERSION="-cachyos-dist"` via merge config.

The kernel release version will be: `<PV>-cachyos-cachyos-dist`
(base version + localversion file + CONFIG_LOCALVERSION).

The eclass checks: `KV_FULL starts with dist-kernel_PV_to_KV(PV)`.
For PV=6.19.10, expected prefix is `6.19.10`. This should pass as long as
the CachyOS tarball contains the correct kernel version.

If this fails, check:
- The CachyOS tarball contains the right kernel version in its top-level Makefile
- No patches accidentally change VERSION/PATCHLEVEL/SUBLEVEL in the Makefile

### Genpatches fail to apply

This usually means a genpatches patch conflicts with CachyOS patches.
To debug:

1. Identify which genpatch fails from the build log
2. Check if it needs to be added to `genpatch_exclude`
3. Compare with `cachyos-sources` to see if it has the same exclusion

### LTO build fails with GCC

LTO (`llvm-lto-thin`, `llvm-lto-full`, `llvm-lto-thin-dist`) requires
`USE=clang`. The `REQUIRED_USE` enforces this, but if somehow bypassed,
the kernel build will fail because GCC doesn't support `CONFIG_LTO_CLANG_*`.

### Config option not found / scripts/config fails

CachyOS config options (like `CACHY`, `SCHED_BORE`, `CC_OPTIMIZE_FOR_PERFORMANCE_O3`)
are added by CachyOS patches. If `scripts/config` fails to set them, it likely
means the CachyOS patches weren't applied correctly, or the files directory
is missing for this version.
