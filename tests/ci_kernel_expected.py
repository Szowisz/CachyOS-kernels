#!/usr/bin/env python3
"""Shared CI helpers for kernel build/version checks.

Two small pieces, each consumed by more than one place:

- `expected_symbols()`: which CONFIG lines must survive `make olddefconfig`
  for one cachyos-sources version and USE case, including effective ebuild
  defaults. Consumed by tests/ci-kernel-kbuild.sh (post-sync assertion) and
  covered by tests/test-ci-kernel-kbuild.py drift fixtures.
- `affected_versions()`: map changed repo paths to the retained
  cachyos-sources versions worth merge-testing. Consumed identically by the
  glibc and musl detect-versions jobs.

Keep these functions literal and greppable; no generic CI framework.
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]


def parse_iuse(source: str) -> set[str]:
    return set(re.search(r'^IUSE="([^"]*)"', source, re.M).group(1).split())


def effective_flags(source: str, overrides: str) -> set[str]:
    """USE flags effective for one case: `+` IUSE defaults +/- overrides."""
    enabled = {f[1:] for f in parse_iuse(source) if f.startswith("+")}
    for word in overrides.split():
        if word.startswith("-"):
            enabled.discard(word[1:])
        else:
            enabled.add(word)
    return enabled


def validate_case(source: str, overrides: str) -> None:
    """Reject unknown flags / REQUIRED_USE violations; raise ValueError."""
    from portage.dep import check_required_use
    iuse = parse_iuse(source)
    available = {f.lstrip("+-") for f in iuse}
    for word in overrides.split():
        if word.lstrip("-") not in available:
            raise ValueError(f"unknown USE flag: {word}")
    required = re.search(r'^REQUIRED_USE="([^"]*)"', source, re.M).group(1)
    required = required.replace("${LLVM_REQUIRED_USE}", "")
    required = re.sub(r"!?llvm_slot_\d+", "", required)
    result = check_required_use(required, effective_flags(source, overrides),
                                available.__contains__, eapi="8")
    if not result:
        raise ValueError(f"invalid USE case: {result.tounicode()}")


# Flag -> config expectation. value `None` emits `# CONFIG_S is not set`.
# Keys cover only symbols the effective flag set decides: schedulers, LLVM
# features, CACHY and AUFS_FS are always set/unset explicitly by the ebuild.
SELECTOR_CONFIG = {
    "bore": [("SCHED_BORE", "y")],
    "rt-bore": [("SCHED_BORE", "y"), ("PREEMPT_RT", "y")],
    "cachyos-hardened": [("SCHED_BORE", "y")],
    "deckify": [("SCHED_BORE", "y"), ("ACPI_CALL", "y")],
    "bmq": [("SCHED_ALT", "y"), ("SCHED_BMQ", "y")],
    "bmq-lfbmq": [("SCHED_ALT", "y"), ("SCHED_BMQ", "y")],
    "pds": [("SCHED_ALT", "y"), ("SCHED_BMQ", None), ("SCHED_PDS", "y")],
    "muqss": [("SCHED_MUQSS", "y")],
    "rt": [("PREEMPT_RT", "y")],
    "eevdf": [],
    "server": [],
    "llvm-lto-thin": [("LTO_CLANG_THIN", "y"), ("LTO_NONE", None)],
    "llvm-lto-thin-dist": [("LTO_CLANG_THIN_DIST", "y"), ("LTO_NONE", None)],
    "llvm-lto-full": [("LTO_CLANG_FULL", "y"), ("LTO_NONE", None)],
    "llvm-lto-none": [("LTO_NONE", "y"), ("LTO_CLANG_THIN", None),
                      ("LTO_CLANG_THIN_DIST", None), ("LTO_CLANG_FULL", None)],
    "autofdo": [("AUTOFDO_CLANG", "y")],
    "propeller": [("PROPELLER_CLANG", "y")],
    "kcfi": [("CFI", "y")],
    "aufs": [("AUFS_FS", "m")],
    "tickrate-full": [("NO_HZ_FULL", "y")],
    "tickrate-idle": [("NO_HZ_IDLE", "y")],
    "tickrate-periodic": [("HZ_PERIODIC", "y")],
    "per-gov": [("CPU_FREQ_DEFAULT_GOV_PERFORMANCE", "y")],
    "o3": [("CC_OPTIMIZE_FOR_PERFORMANCE_O3", "y")],
    "os": [("CC_OPTIMIZE_FOR_SIZE", "y")],
    "debug": [("CC_OPTIMIZE_FOR_SIZE", "y")],
    "bbr3": [("TCP_CONG_BBR3", "y"), ("DEFAULT_TCP_CONG", '"bbr3"')],
    "hugepage-always": [("TRANSPARENT_HUGEPAGE_ALWAYS", "y")],
    "hugepage-madvise": [("TRANSPARENT_HUGEPAGE_MADVISE", "y")],
    "mnative": [("X86_NATIVE_CPU", "y")],
    "mzen4": [("MZEN4", "y")],
}
for _level in range(1, 5):
    SELECTOR_CONFIG[f"mgeneric-v{_level}"] = [("GENERIC_CPU", "y"),
                                             ("X86_64_VERSION", str(_level))]
for _hz in (100, 250, 500, 600, 750, 1000):
    SELECTOR_CONFIG[f"hz-ticks-{_hz}"] = [(f"HZ_{_hz}", "y"), ("HZ", str(_hz))]
SELECTOR_CONFIG["hz-ticks-300"] = [("HZ_300", "y"), ("HZ", "300")]

# Mutually exclusive scheduler family: the effective selection is asserted
# on, every alternative is asserted off. Covers default-on bore on 7.x too.
_SCHEDULER_FLAGS = ("bore", "bmq", "bmq-lfbmq", "pds", "muqss", "rt", "rt-bore",
                    "cachyos-hardened", "deckify", "eevdf")
_SCHEDULER_SYMBOLS = ("SCHED_BORE", "SCHED_ALT", "SCHED_BMQ", "SCHED_PDS",
                      "SCHED_MUQSS", "PREEMPT_RT")


def expected_symbols(ebuild: Path, overrides: str) -> list[tuple[str, str | None]]:
    """Config assertions for the effective case (defaults + overrides).

    A disabled flag contributes its symbols' negative expectation when the
    ebuild actively controls them (schedulers, LTO family, CACHY, AUFS).
    """
    source = ebuild.read_text()
    available = {f.lstrip("+-") for f in parse_iuse(source)}
    enabled = effective_flags(source, overrides)
    explicit = set(overrides.split())
    rt_selected = bool(enabled & {"rt", "rt-bore"})
    expectations: list[tuple[str, str | None]] = []
    seen: set[tuple[str, str | None]] = set()

    def add(symbol: str, value: str | None) -> None:
        # First writer wins: enabled-flag positives are emitted before the
        # family-wide negatives below.
        if (symbol, value) not in seen and not any(
                s == symbol for s, _ in seen if s == symbol):
            seen.add((symbol, value))
            expectations.append((symbol, value))

    for flag in sorted(enabled):
        # LTS IUSE defaults THP on, but RT's Kconfig disables it. An explicit
        # request still gets checked and fails rather than disappearing.
        if rt_selected and flag.startswith("hugepage-") and flag not in explicit:
            continue
        for symbol, value in SELECTOR_CONFIG.get(flag, []):
            add(symbol, value)
    if rt_selected:
        add("TRANSPARENT_HUGEPAGE", None)
    else:
        add("PREEMPT_DYNAMIC", "y")
        # Legacy MuQSS ports use their own preemption choice names.
        suffix = ("_NODEF" if "muqss" in enabled and "PREEMPT_LAZY_NODEF" in source
                  else "")
        if "preempt-full" in enabled:
            add("PREEMPT" + suffix, "y")
        elif "preempt-lazy" in enabled:
            add("PREEMPT_LAZY" + suffix, "y")
    # PREEMPT_RT disables THP in mm/Kconfig; only non-RT variants inherit a mode.
    if not rt_selected and not enabled & {"hugepage-always", "hugepage-madvise"}:
        add("TRANSPARENT_HUGEPAGE_MADVISE" if "server" in enabled
            else "TRANSPARENT_HUGEPAGE_ALWAYS", "y")
    # Assert the unselected scheduler alternatives stay off.
    for symbol in _SCHEDULER_SYMBOLS:
        if not any(s == symbol for s, _ in seen):
            add(symbol, None)
    # Symbols the ebuild always sets or unsets: never assume a neutral kernel
    # default — assert the disabled state too.
    if "server" in available:
        if not any(s == "CACHY" for s, _ in seen):
            add("CACHY", None if "server" in enabled else "y")
    elif "server" in enabled:
        add("CACHY", None)
    if "aufs" in available and "aufs" not in enabled:
        add("AUFS_FS", None)
    if "kcfi" in available and "kcfi" not in enabled:
        add("CFI", None)
    return expectations


# --- Affected-version detection -------------------------------------------

EBUILD_RE = re.compile(
    r"^sys-kernel/cachyos-(sources|kernel)/cachyos-\1-([^/]+)\.ebuild$")
PATCH_RE = re.compile(
    r"^sys-kernel/(cachyos-sources|cachyos-kernel)/files/(.+\.patch)$")
# Helper changes exercise every retained merged source package.
HELPER_RE = re.compile(
    r"^tests/(ci[-_].*\.(sh|py)|test-ci-.*\.py|test-source-features\.py)$")
WORKFLOWS = {
    ".github/workflows/ebuild-test.yml",
    ".github/workflows/ebuild-test-musl-llvm.yml",
    ".github/workflows/ebuild-kernel-build.yml",
    ".github/workflows/ebuild-binpkg-cleanup.yml",
}


def _version_key(version: str) -> list[int]:
    base, _, revision = version.partition("-r")
    return [int(x) for x in base.split(".")] + [int(revision or 0)]


def retained_versions(repo: Path = ROOT) -> list[str]:
    return sorted(
        (p.name.removeprefix("cachyos-sources-").removesuffix(".ebuild")
         for p in (repo / "sys-kernel/cachyos-sources").glob("cachyos-sources-*.ebuild")
         if "9999" not in p.name),
        key=_version_key)


def patch_consumers(patch_name: str, repo: Path = ROOT) -> list[str]:
    """Retained source ebuilds referencing a files/ patch basename.

    `cachyos-kernel/files` is a symlink to the sources dir and kernel ebuilds
    share patch names, so source ebuilds cover both packages.
    """
    consumers = []
    for ebuild in sorted((repo / "sys-kernel/cachyos-sources").glob("*.ebuild")):
        if "9999" in ebuild.name:
            continue
        refs = re.findall(r'\$\{FILESDIR\}/([^\s"]+\.patch)', ebuild.read_text())
        basenames = {Path(ref).name for ref in refs}
        # `${prjc}`-style variable slots: a concrete patch name matches the
        # literal pattern with the variable replaced by `prjc`.
        if patch_name in basenames or any(
                ref.replace("${prjc}", "prjc") == patch_name for ref in basenames):
            consumers.append(ebuild.stem.removeprefix("cachyos-sources-"))
    return consumers


def affected_versions(changed_paths: list[str], repo: Path = ROOT) -> list[str]:
    """Versions to test for one changed-path list; retained versions only.

    - a cachyos-sources/cachyos-kernel ebuild -> its retained source version
    - a files/ patch -> every retained ebuild referencing it
    - a kbuild helper change or one of the CI workflows -> all retained
    - anything else -> none (the caller decides whether to skip the run)
    """
    versions: set[str] = set()
    retained = set(retained_versions(repo))
    helper_changed = False
    for path in changed_paths:
        match = EBUILD_RE.match(path)
        if match and "9999" not in match.group(2):
            stem = match.group(2)
            for candidate in {stem, stem.split("-r")[0]}:
                if candidate in retained:
                    versions.add(candidate)
            continue
        match = PATCH_RE.match(path)
        if match:
            versions.update(patch_consumers(Path(match.group(2)).name, repo))
            continue
        if HELPER_RE.match(path) or path in WORKFLOWS:
            helper_changed = True
    if helper_changed:
        versions |= retained
    return sorted(versions, key=_version_key)


def main() -> None:
    """CLI used by the shell helper and the workflows.

    expected <ebuild> [use...] -> one `CONFIG_S=y` / `# CONFIG_S is not set`
                                per line for the effective case.
    validate <ebuild> [use...] -> exit nonzero on unknown/illegal flag case.
    detect                     -> newline versions for paths on stdin.
    """
    if len(sys.argv) >= 2 and sys.argv[1] == "expected":
        for symbol, value in expected_symbols(Path(sys.argv[2]),
                                              " ".join(sys.argv[3:])):
            print(f"# CONFIG_{symbol} is not set" if value is None
                  else f"CONFIG_{symbol}={value}")
        return
    if len(sys.argv) >= 2 and sys.argv[1] == "validate":
        try:
            validate_case(Path(sys.argv[2]).read_text(), " ".join(sys.argv[3:]))
        except ValueError as error:
            raise SystemExit(str(error))
        return
    if len(sys.argv) == 2 and sys.argv[1] == "detect":
        print("\n".join(affected_versions(
            [line.strip() for line in sys.stdin if line.strip()])))
        return
    raise SystemExit(
        "usage: ci_kernel_expected.py expected|validate <ebuild> [use...] | detect")


if __name__ == "__main__":
    main()
