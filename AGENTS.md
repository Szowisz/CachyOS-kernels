# CachyOS-kernels AGENTS.md

> **Repo**: Gentoo overlay for CachyOS kernel ebuilds (sources, dist-kernel, binary, virtuals)
> **Packaging/version metadata**: https://github.com/CachyOS/linux-cachyos
> **Canonical patch and kernel sources**: https://github.com/CachyOS/kernel-patches and https://github.com/CachyOS/linux

---

## Highest-Priority Work — Do This Before Routine Version Bumps

### 1. Audit every ebuild against upstream for complete synchronization

**The first responsibility of every update pass is to verify that the ebuild contents still match upstream, not merely that package versions match.** Compare every relevant ebuild with the current upstream packaging metadata, source trees, release assets, patch sets, configuration fragments, and binary mirror contents. Track upstream additions, removals, renames, and behavior changes downstream in the same pass.

At minimum, audit:
- USE flags and scheduler/kernel variants
- patch selection and application order
- Kconfig/config-fragment wiring and defaults
- dependencies, source URIs, release/pkgrel mappings, and binary asset names
- installed files, package splits, build options, and mutually exclusive combinations

Do not copy an old ebuild, change only its version, and assume it is current. For every upstream capability, identify the corresponding ebuild USE flag/logic, or document a concrete compatibility reason for excluding it. When upstream removes or renames functionality, remove or rename the stale downstream flag, conditional branch, patch reference, and distfile entry as appropriate. Whenever a package adds, removes, or renames a local USE flag, update its `metadata.xml` flag description in the same change. The audit must cover `cachyos-sources`, `cachyos-kernel`, and `cachyos-kernel-bin` independently because their upstream feature sets can differ.

### 2. Exhaustively mine both canonical CachyOS kernel repositories

**Do not rely only on `linux-cachyos`, `.SRCINFO`, documented/default variants, or release notes.** Treat the following as the authoritative places to discover the complete CachyOS kernel feature set and inspect them thoroughly on every update pass:
- https://github.com/CachyOS/kernel-patches
- https://github.com/CachyOS/linux

Fetch all branches and tags, then inspect current and historical patch directories, series files, config fragments, commits, release-tag diffs, and features that are unadvertised, disabled by default, omitted from normal packaging metadata, or otherwise hidden from the usual build path. For `CachyOS/linux`, compare the relevant CachyOS release tag/tree with the matching vanilla kernel so patches carried only in the pre-patched tree are not missed. Do not assume that the default branch or the currently advertised package variants provide complete coverage.

Every viable upstream-provided feature must be surfaced in the Gentoo ebuilds with explicit, granular USE flags and the required patch/config logic, rather than silently omitted merely because CachyOS does not advertise it. This explicitly includes scheduler patch families such as `prjc` and `prjc-lfbmq`, and applies equally to any similarly concealed or non-default feature discovered later. “Include every feature” means making incompatible alternatives selectable, not applying mutually exclusive patches simultaneously: encode conflicts/dependencies in `REQUIRED_USE`, verify per-kernel-version applicability, and fail clearly for unsupported combinations.

For each update, keep an explicit inventory mapping:

```text
upstream patch/config/feature -> ebuild USE flag and implementation
                              -> or documented technical exclusion
```

Before declaring an update complete, diff that inventory against the previous pass so newly added features are exposed and deleted features are retired. Regenerate manifests and run the applicable prepare/package/unpack tests after changing feature coverage.

---

## Package Architecture

```
app-admin/
  cachyos-settings/      # CachyOS system settings/configuration package
  ananicy-cpp/           # Ananicy C++ service bundled with CachyOS rules
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

**Follow upstream `linux-cachyos` commits and CachyOS `linux` release tags**, NOT kernel.org releases.

Upstream pages:
- Version/config commits: https://github.com/CachyOS/linux-cachyos/commits/
- Pre-patched releases and same-version pkgrel bumps: https://github.com/CachyOS/linux/releases

Each `linux-cachyos` commit message describes which versions were bumped, e.g.:
- `7.0.3-1 && 6.18.26-1` → create ebuilds for 7.0.3 and 6.18.26 only
- `6.19.12-1 && 6.18.22-1` → create ebuilds for 6.19.12 and 6.18.22 only

Also check `CachyOS/linux` releases for a newer pkgrel of an already packaged version. Map the CachyOS release suffix to the Gentoo revision:
- `cachyos-7.1.4-1` → `cachyos-sources-7.1.4` / `cachyos-kernel-7.1.4`
- `cachyos-7.1.4-2` → `cachyos-sources-7.1.4-r1` / `cachyos-kernel-7.1.4-r1`

A same-version release pkgrel bump can appear before or without a matching new `linux-cachyos` commit, so a commit-only check is insufficient. For `cachyos-kernel-bin`, independently inspect the mirror because source release pkgrel and binary package pkgrel can differ.

Do NOT auto-generate ebuilds for other kernel.org versions (6.12, 6.6, etc.) just because they exist on kernel.org.

**Also check `app-admin/cachyos-settings` and `app-admin/ananicy-cpp` during every CachyOS update pass.** They are not tied to kernel versions, but they are part of the overlay's CachyOS package set and can be bumped independently:
- `app-admin/cachyos-settings` tracks upstream `CachyOS/CachyOS-Settings` tags/releases.
- `app-admin/ananicy-cpp` tracks upstream `ananicy-cpp/ananicy-cpp` tags/releases and the bundled `CachyOS/ananicy-rules` commit.

---

## Step-by-Step Update Workflow

### 1. cachyos-sources (always first)

```bash
# Prefer an explicit version derived from linux-cachyos commits + CachyOS/linux releases:
python3 ./sys-kernel/cachyos-sources/script/update_ebuild.py --version 7.1.4-r1

# For LTS versions, specify --lts and --version:
python3 ./sys-kernel/cachyos-sources/script/update_ebuild.py --lts --version 6.18.26

# For a variant-only Gentoo revbump with no new CachyOS source release,
# pin the source pkgrel that actually exists (for example, cachyos-7.1.8-1):
python3 ./sys-kernel/cachyos-sources/script/update_ebuild.py \
  --version 7.1.8-r1 --source-pkgrel 1

# The no-argument mode consults kernel.org and is NOT authoritative for this overlay.
# Use it only for diagnostics, never as the update trigger:
python3 ./sys-kernel/cachyos-sources/script/update_ebuild.py --dry-run
```

The script does:
- Creates ebuild from latest template
- Fetches upstream config versions for USE flag availability
- Pins `CACHYOS_PATCHES_COMMIT` and `CACHYOS_CONFIGS_COMMIT`
- Regenerates the Manifest for commit-pinned GitHub `SRC_URI` patch/config files

**Manually verify after script runs:**
- `K_GENPATCHES_VER` aligns with official `gentoo-sources` when Gentoo has published the matching version (see Genpatches section below); if Gentoo has not caught up but CachyOS upstream has, follow the CachyOS upstream target and document the temporary Gentoo-reference gap
- Every upstream patch/config used by the ebuild has a commit-pinned `SRC_URI` and unique distfile name
- Apply-test each exposed variant; keep a concrete technical exclusion when an upstream patch does not apply to the exact source release
- For variant-only revbumps, the pinned `CACHYOS_PR` points to an existing `CachyOS/linux` release asset; do not let Gentoo `-rN` imply a nonexistent source pkgrel

### 2. cachyos-kernel

```bash
# Copy from latest kernel ebuild
cp cachyos-kernel-<OLD_VER>.ebuild cachyos-kernel-<NEW_VER>.ebuild

# Update these values from cachyos-sources:
#   GENPATCHES_VER          ← K_GENPATCHES_VER (from sources ebuild)
#   ZFS_COMMIT              ← ZFS_COMMIT (from sources ebuild)
#   CACHYOS_PATCHES_COMMIT  ← same pin as sources ebuild
#   CACHYOS_CONFIGS_COMMIT  ← same pin as sources ebuild
#   PDEPEND                 ← auto: >=virtual/dist-kernel-${PV}

# Generate manifest
ebuild sys-kernel/cachyos-kernel/cachyos-kernel-<VERSION>.ebuild manifest

# Test (unpack + prepare only, NO build):
sudo ebuild sys-kernel/cachyos-kernel/cachyos-kernel-<VERSION>.ebuild clean prepare
```

**Important**: The kernel ebuild may reference shared patch directories like `${FILESDIR}/6.19.0/misc/0002-fix-autofdo-propeller-lto-thin-dist.patch`. Ensure these shared patch dirs exist in `cachyos-sources/files/` (the symlink resolves them).

### 3. cachyos-kernel-bin

**Bin kernel tracks the latest mainline kernel, the latest LTS kernel, AND hardened coverage** (if upstream provides them). If the latest mainline/LTS bin ebuilds do not include `cachyos-hardened`/hardened packages but the mirror still provides a hardened-capable version, keep the latest mirrored hardened-capable bin ebuild too. Old bin ebuilds that are none of latest mainline, latest LTS, or latest hardened coverage should be removed.

**When updating a bin ebuild, always `mv` the old ebuild to the new version first, then edit it.** Do NOT `cp` and keep the old ebuild around — upstream stops hosting old binaries, so running `ebuild manifest` on the old version will fail because the distfiles are no longer downloadable. Renaming instead of copying avoids this problem.

For each new version, the bin packages may have DIFFERENT scheduler variant availability on CachyOS mirrors. Always check:
```bash
curl -s https://mirror.cachyos.org/repo/x86_64_v3/cachyos-v3/ | \
  grep -oP "linux-cachyos[^\"]*-${VERSION}-${PKGREL}-x86_64_v3\.pkg\.tar\.zst" | sort -u
```

The USE flags must match exactly what's available on the mirror. If a variant (e.g., `cachyos-hardened`, `deckify`) doesn't exist for this version, remove it from IUSE/REQUIRED_USE/SRC_URI.

### 3a. cachyos-kernel-bin Variant Coverage Rules

**Core principle: the ebuild MUST cover every upstream bin variant available on the mirror.**

Every time a new bin ebuild is created, check all available packages on the CachyOS mirror:
```bash
curl -s https://mirror.cachyos.org/repo/x86_64_v3/cachyos-v3/ | \
  grep -oP "linux-cachyos[^\"]*-${VERSION}-${PKGREL}-x86_64_v3\.pkg\.tar\.zst" | sort -u
```

IUSE / REQUIRED_USE / SRC_URI must precisely cover all combinations on the mirror. If a variant (e.g., `cachyos-hardened`, `deckify`) doesn't exist for this version, remove it from the ebuild. Conversely, if it exists, it MUST be added.

**LTO / GCC USE flags follow the same principle:** only provide `lto` or `gcc` USE when the mirror has the corresponding packages. For example, 6.18.26 LTS only has `linux-cachyos-lts` (no lto variant), so the ebuild does not need an `lto` USE.

**Variant selection uses `^^ ( ... )` mutual exclusion:** even when only one variant option exists for a version (e.g., hardened-only or lts-only), use this pattern for structural consistency.

Typical IUSE per version:

| Version | Mirror variants | IUSE | REQUIRED_USE |
|---------|----------------|------|-------------|
| Mainline (7.x) | cachyos/default (lto or gcc), bore, bmq, eevdf, rt-bore, server, deckify, cachyos-hardened as mirror provides; scheduler variants usually have lto/non-lto | `+cachyos bore bmq eevdf rt-bore server deckify cachyos-hardened +lto gcc debug` | `^^ ( cachyos bore bmq eevdf rt-bore server deckify cachyos-hardened ) ?? ( lto gcc ) cachyos? ( || ( lto gcc ) ) gcc? ( cachyos )` |
| 6.19.x (hardened-only) | hardened + hardened-lto | `hardened lto debug` | `hardened` |
| 6.18.x (LTS) | lts (single package, no lto) | `lts debug` | `lts` |

**Variant → package name mapping reference:** see `sys-kernel/cachyos-kernel-bin/AGENT.md`.

**Checklist for new bin ebuilds:**
1. Check mirror for all available variants and their lto/non-lto combinations
2. Set IUSE to cover all available variants + `lto` (if available) + `gcc` (if available) + `debug`
3. Ensure REQUIRED_USE `^^ ( ... )` includes all variant options
4. Update `_cachyos_pkg_variant()` and verify `_cachyos_variant_suffix()`, `_cachyos_bin_distfile()`, `_cachyos_headers_distfile()` outputs
5. Compare against the previous ebuild: confirm no missing variants, and remove variants not on the mirror

### 4. virtual/dist-kernel

```bash
cp virtual/dist-kernel/dist-kernel-<OLD_VER>.ebuild virtual/dist-kernel/dist-kernel-<NEW_VER>.ebuild
ebuild virtual/dist-kernel/dist-kernel-<VERSION>.ebuild manifest
```

The virtual simply depends on `>=sys-kernel/cachyos-sources-${PV}` for source packages and `>=sys-kernel/cachyos-kernel-${PV}` through the dist-kernel eclass.

### 5. app-admin/cachyos-settings (check every update pass)

`app-admin/cachyos-settings` is not tied to kernel PVs, but should be checked whenever refreshing CachyOS packages:

```bash
# Check current upstream tags/releases:
git ls-remote --tags --sort='v:refname' https://github.com/CachyOS/CachyOS-Settings.git 'refs/tags/*' | tail

# If newer than the overlay ebuild, copy the latest ebuild and update manifest:
cp app-admin/cachyos-settings/cachyos-settings-<OLD_VER>.ebuild \
   app-admin/cachyos-settings/cachyos-settings-<NEW_VER>.ebuild
ebuild app-admin/cachyos-settings/cachyos-settings-<NEW_VER>.ebuild manifest
```

After bumping, verify the installed file layout still matches the ebuild (`src_install`) because upstream may add/remove config directories, systemd units, udev rules, or optional zram/X11 files.

### 6. app-admin/ananicy-cpp (check every update pass)

`app-admin/ananicy-cpp` packages Ananicy C++ plus CachyOS' bundled ananicy rules. Check both upstreams whenever refreshing CachyOS packages:

```bash
# Check current upstream app tags/releases:
git ls-remote --tags --sort='v:refname' https://gitlab.com/ananicy-cpp/ananicy-cpp.git 'refs/tags/v*' | tail

# Check current CachyOS rules commit:
git ls-remote https://github.com/CachyOS/ananicy-rules.git HEAD
```

Update rules:
- If upstream `ananicy-cpp` has a newer tag, copy the latest ebuild to the new Gentoo PV and regenerate Manifest.
- Always compare `ANANICY_COMMIT` with `CachyOS/ananicy-rules` `HEAD`; when bumping the app, update `ANANICY_COMMIT` to the current rules commit unless there is a known compatibility reason not to.
- If only `CachyOS/ananicy-rules` changed and `ananicy-cpp` did not, create a revision bump (e.g. `ananicy-cpp-<PV>-r1.ebuild`) instead of editing an existing ebuild in place, then update `ANANICY_COMMIT` and Manifest.
- Preserve `MYPV="${PV/_rc/-rc}"`; upstream archive names use `-rc` while Gentoo PVs use `_rc`.
- After bumping, verify `SRC_URI` fetches both the GitLab app archive and the GitHub rules archive, and verify `src_install` still installs the OpenRC init script plus `/etc/ananicy.d` rules.

```bash
cp app-admin/ananicy-cpp/ananicy-cpp-<OLD_VER>.ebuild \
   app-admin/ananicy-cpp/ananicy-cpp-<NEW_VER>.ebuild
# edit ANANICY_COMMIT if the rules commit changed
ebuild app-admin/ananicy-cpp/ananicy-cpp-<NEW_VER>.ebuild manifest
```

---

## Genpatches Version Alignment

**When official Gentoo `gentoo-sources` has the matching version, the genpatches version MUST match it.** If CachyOS upstream publishes a target before Gentoo adds the matching `gentoo-sources`/`gentoo-kernel` ebuilds, still follow the CachyOS upstream trigger; use the latest available matching-branch genpatches tarballs, document the Gentoo-reference gap in the update notes, and re-check alignment when Gentoo catches up.

The auto-generated version from `update_ebuild.py` can be WRONG (especially for LTS). Always verify when a reference exists:

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

**Delete ebuilds whose version does NOT exist in the corresponding official Gentoo package, except for the current CachyOS upstream target when Gentoo has not caught up yet:**

| Our package | Reference package |
|-------------|------------------|
| `cachyos-sources` | `/var/db/repos/gentoo/sys-kernel/gentoo-sources/` |
| `cachyos-kernel` | `/var/db/repos/gentoo/sys-kernel/gentoo-kernel/` |
| `cachyos-kernel-bin` | Keep latest mainline + latest LTS (if upstream has one) + latest mirrored hardened coverage if separate |
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
# Stage all new/modified files (ebuilds, files dirs, manifests, app-admin packages, virtual/dist-kernel, AGENTS.md)
git add -v app-admin/cachyos-settings/ app-admin/ananicy-cpp/
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
- `app-admin/ananicy-cpp: update to 1.2.1`
- `app-admin/ananicy-cpp: revbump for CachyOS ananicy rules`

---

## Testing

### cachyos-sources (full test):
```bash
# Prefer this to avoid sudo and keep build files in repo-owned path (easy to inspect):
PORTAGE_TMPDIR="$PWD/.ci/portage-tmp" ebuild sys-kernel/cachyos-sources/cachyos-sources-<VER>.ebuild clean package

# Legacy:
sudo ebuild sys-kernel/cachyos-sources/cachyos-sources-<VER>.ebuild clean package
```

### cachyos-kernel (prepare only, NEVER build):
```bash
# Prefer this to avoid sudo and keep build files in repo-owned path:
PORTAGE_TMPDIR="$PWD/.ci/portage-tmp" ebuild sys-kernel/cachyos-kernel/cachyos-kernel-<VER>.ebuild clean prepare

# Legacy:
sudo ebuild sys-kernel/cachyos-kernel/cachyos-kernel-<VER>.ebuild clean prepare
```

### cachyos-kernel-bin (unpack only):
```bash
# Prefer this to avoid sudo and keep build files in repo-owned path:
PORTAGE_TMPDIR="$PWD/.ci/portage-tmp" ebuild sys-kernel/cachyos-kernel-bin/cachyos-kernel-bin-<VER>.ebuild clean unpack

# Legacy:
sudo ebuild sys-kernel/cachyos-kernel-bin/cachyos-kernel-bin-<VER>.ebuild clean unpack
```

### virtual/dist-kernel (manifest check only):
```bash
# Optional non-root run when needed:
PORTAGE_TMPDIR="$PWD/.ci/portage-tmp" ebuild virtual/dist-kernel/dist-kernel-<VER>.ebuild manifest

ebuild virtual/dist-kernel/dist-kernel-<VER>.ebuild manifest
```

### cachyos-settings (install test):
```bash
# Prefer repo-owned tempdir for easy inspection:
PORTAGE_TMPDIR="$PWD/.ci/portage-tmp" ebuild app-admin/cachyos-settings/cachyos-settings-<VER>.ebuild clean install

# Legacy:
sudo ebuild app-admin/cachyos-settings/cachyos-settings-<VER>.ebuild clean install
```

### ananicy-cpp (install test):
```bash
# Prefer repo-owned tempdir for easy inspection:
PORTAGE_TMPDIR="$PWD/.ci/portage-tmp" ebuild app-admin/ananicy-cpp/ananicy-cpp-<VER>.ebuild clean install

# Legacy:
sudo ebuild app-admin/ananicy-cpp/ananicy-cpp-<VER>.ebuild clean install
```

---

## Commit

After all tests pass and manifests are regenerated:

```bash
# First commit: version update (add new ebuilds, files, manifests, app-admin packages, virtual, AGENTS.md)
git add -v app-admin/cachyos-settings/ app-admin/ananicy-cpp/ sys-kernel/cachyos-sources/ sys-kernel/cachyos-kernel/
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

- `hardened`: Availability varies by upstream source/kernel config; `update_ebuild.py` checks `.SRCINFO` before keeping/restoring it
- `bmq`: Availability varies by upstream config; `update_ebuild.py` checks `.SRCINFO` before keeping/restoring it

When manually creating kernel ebuilds, sync USE flag changes from the corresponding `cachyos-sources` ebuild.

### Bin kernel USE flags

For `cachyos-kernel-bin`, USE flags must reflect the exact combinations available on CachyOS mirrors. Each binary variant (`cachyos`, `bore`, `bmq`, `eevdf`, `cachyos-hardened`, `deckify`, `rt-bore`, `server`, `lts`) may or may not have LTO/non-LTO/GCC variants available at a given version.

---

## Common Pitfalls

### Permission-friendly ebuild troubleshooting

在排障时可直接指定 portage 临时工作目录，避免 `sudo ebuild` 产生的权限问题并便于直接读取构建日志：

```bash
# 统一建议在仓库根执行
mkdir -p .ci/portage-tmp
PORTAGE_TMPDIR="$PWD/.ci/portage-tmp" ebuild ... clean prepare
# 或 clean unpack/test/package 按需替换
```



1. **Don't blindly update all kernel.org versions** — only follow upstream linux-cachyos commits
2. **Genpatches version from the script may be wrong** for LTS — always verify against gentoo-sources
3. **Shared patch directories** (`files/6.19.0/`, `files/6.18.10/`) are version-independent — don't delete during cleanup
4. **cachyos-kernel/files is a symlink** to cachyos-sources/files — changes to one affect both
5. **cachyos-kernel-bin keeps latest mainline + latest LTS + latest hardened coverage when separate** — remove old bin ebuilds that are none of those. Every upstream bin variant must be covered by the ebuild's USE flags; if the mirror lacks an lto variant, omit the `lto` USE
6. **Manifest must be regenerated** after adding/removing any ebuild
7. **`ebuild ... manifest` may need sudo** for binpkgs directory access

---

## File Reference

```
sys-kernel/cachyos-sources/
  script/update_ebuild.py    # creates ebuilds and pins upstream patch/config commits
  files/                     # overlay-owned patches/scripts; upstream files come from SRC_URI

sys-kernel/cachyos-kernel/
  files -> ../cachyos-sources/files   # SYMLINK

sys-kernel/cachyos-kernel-bin/
  AGENT.md                    # detailed bin kernel guide

app-admin/cachyos-settings/
  cachyos-settings-*.ebuild   # CachyOS settings/config package

app-admin/ananicy-cpp/
  ananicy-cpp-*.ebuild        # Ananicy C++ service with CachyOS rules

Upstream:
  https://github.com/CachyOS/linux-cachyos/commits/    # version bump trigger
  https://github.com/CachyOS/linux/releases             # pre-patched tarballs
  https://github.com/CachyOS/kernel-patches             # patch source
  https://github.com/CachyOS/CachyOS-Settings           # settings package tags/releases
  https://gitlab.com/ananicy-cpp/ananicy-cpp            # ananicy-cpp source tags/releases
  https://github.com/CachyOS/ananicy-rules              # bundled CachyOS ananicy rules
  https://mirror.cachyos.org/repo/                      # binary packages

Reference (read-only):
  /var/db/repos/gentoo/sys-kernel/gentoo-sources/       # genpatches alignment
  /var/db/repos/gentoo/sys-kernel/gentoo-kernel/        # kernel genpatches cross-ref
  /var/db/repos/gentoo/sys-kernel/gentoo-kernel-bin/    # bin kernel reference
```
