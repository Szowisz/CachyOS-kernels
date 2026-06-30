# CachyOS package sweep 2026-06-30

Branch: `xz/cachyos-package-sweep-20260630`

## Evidence snapshot

- `CachyOS/linux-cachyos` latest stable-relevant commits:
  - `4c9deb3 7.1.2-1 && 6.18.37-1`
  - `7ce3d16 7.1.2-1: Tagrel 2 to fix amdgpu shutdown issue`
  - `f8f255b 7.1: update tagrel`
- `CachyOS/linux` tags exist for `cachyos-7.1.2-1`, `-2`, `-3`, and `cachyos-6.18.37-1`.
- Local source/build ebuilds previously covered `7.1.2-r1` and `6.18.37`; this pass revbumps `7.1.2-r2` to follow upstream tagrel/pkgrel 3 while preserving `K_GENPATCHES_VER=3`/`GENPATCHES_VER=3` and ZFS commit `c681af76c5a6a15caada25eb13090e41218c7831`.
- Mirror `x86_64_v3/cachyos-v3` exposes bin packages:
  - mainline default `linux-cachyos-7.1.2-3`
  - mainline gcc `linux-cachyos-gcc-7.1.2-2`
  - scheduler variants `bore`, `eevdf`, `rt-bore`, `server` at `7.1.2-1` with lto/non-lto
  - LTS `linux-cachyos-lts-6.18.37-1`
  - hardened coverage still at `7.0.12-1`
- `CachyOS-Settings` latest tag is still `1.3.5` and local overlay has `1.3.5`; no bump needed.
- `ananicy-cpp` latest tag is still `v1.2.0`, but `CachyOS/ananicy-rules` HEAD is `ebf4fa421e128ccb3c16e4a0cbff4a00d06aacdc`, newer than local `702e66092f1306d8bf3e3e6b4ceb0da5fba4353a`.

## Small implementation steps

1. **Source/build kernel tagrel check** — done
   - Created `sys-kernel/cachyos-sources/cachyos-sources-7.1.2-r2.ebuild` and `sys-kernel/cachyos-kernel/cachyos-kernel-7.1.2-r2.ebuild`.
   - Generated `sys-kernel/cachyos-sources/files/7.1.2-r2/` from upstream `kernel-patches` commit `f98908d8b5cacc4c24a6039ffd9f41f6a0de4ba2`.
   - Verified ebuild trailing commit comments match `files/7.1.2-r2/commit`.

2. **Binary kernel update** — done
   - Replaced latest mainline bin ebuild with `cachyos-kernel-bin-7.1.2-r2` because default bin is pkgrel 3 and gcc is pkgrel 2 while schedulers are pkgrel 1.
   - Replaced LTS bin ebuild with `cachyos-kernel-bin-6.18.37`.
   - Kept hardened coverage `cachyos-kernel-bin-7.0.12` because latest mainline/LTS do not provide hardened.
   - Updated `SRC_URI`, PR mapping variables, `PDEPEND`, `virtual/dist-kernel`, and Manifest.

3. **ananicy rules revbump** — done
   - Created `app-admin/ananicy-cpp-1.2.0-r10.ebuild` from `-r9` and updated `ANANICY_COMMIT` to `ebf4fa421e128ccb3c16e4a0cbff4a00d06aacdc`.
   - Removed old `-r9` after confirming the package history keeps only the latest rules revision.

4. **Validation and review** — in progress
   - `git diff --check`: pass.
   - `pkgcheck scan --net app-admin/ananicy-cpp sys-kernel/cachyos-sources sys-kernel/cachyos-kernel sys-kernel/cachyos-kernel-bin virtual/dist-kernel`: pass exit code after fixing invalid `~...-r2` atoms; remaining emitted items are existing QA warnings such as `RedundantVersion`/`SizeViolation`.
   - Ebuild phase checks with repo-local `PORTAGE_TMPDIR` and `PKGDIR`:
     - `cachyos-sources-7.1.2-r2 clean package`: pass.
     - `cachyos-kernel-7.1.2-r2 clean prepare`: pass.
     - `cachyos-kernel-bin-6.18.37 clean unpack`: pass.
     - `cachyos-kernel-bin-7.1.2-r2 clean unpack`: pass for default, `cachyos gcc -lto`, `bore lto -cachyos -gcc`, and `server -lto -cachyos -gcc` representative USE combos.
     - `ananicy-cpp-1.2.0-r10 clean install`: pass.
   - Next: reviewer review, then stage/split commits per repo policy.

## Non-goals

- Do not follow kernel.org-only versions or rc packages unless upstream stable/LTS commit policy requires it.
- Do not add missing binary variants that are not present on mirror for the target version.
- Do not modify upstream-managed unrelated packages.
