# Restore hardened CachyOS bin coverage

## Goal

Restore `sys-kernel/cachyos-kernel-bin` coverage for the latest mirrored CachyOS hardened binary version, because mirror-provided hardened bin variants must not be omitted.

## Current facts

- Mirror `x86_64_v3/cachyos-v3` currently has no `7.1.2` or `6.18.37` bin packages.
- Mirror latest mainline bin remains `7.1.1` and latest LTS bin remains `6.18.36`.
- Mirror still provides hardened packages at `7.0.12-1`.
- Current overlay no longer has a `cachyos-kernel-bin-7.0.12` ebuild.

## Small branch scope

Branch: `xz/restore-hardened-bin-7.0.12`

1. Restore `sys-kernel/cachyos-kernel-bin/cachyos-kernel-bin-7.0.12.ebuild` from the prior known-good version.
2. Restore corresponding `7.0.12` distfile Manifest entries without disturbing current `7.1.1-r1` and `6.18.36` bin entries.
3. Add `~sys-kernel/cachyos-kernel-bin-${PV%_p*}` back to `virtual/dist-kernel/dist-kernel-7.0.12_p1.ebuild`.
4. Run focused checks (`pkgdev manifest`/`pkgcheck` if available and practical; avoid unnecessary huge fetches when historical Manifest hashes already cover the exact distfiles).
5. Commit with `pkgdev commit --signoff` and request reviewer review before considering merge.

## Non-goals

- Do not update source/build kernels; latest `7.1.2` and `6.18.37` are already present.
- Do not bump current mainline/LTS bin versions until mirror publishes `7.1.2`/`6.18.37` binaries.
- Do not add unsupported variants beyond the exact mirror-provided `7.0.12` set.
