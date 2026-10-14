#!/usr/bin/env python3
"""List the literal workflow matrix, omitting only unsupported variants."""

import argparse
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
OPTIONAL_VARIANT_FLAGS = ("bmq", "bmq-lfbmq", "deckify")


def matrix_cases(repo: Path, abi: str) -> list[str]:
    suffix = "-musl-llvm" if abi == "musl" else ""
    workflow = (repo / f".github/workflows/ebuild-test{suffix}.yml").read_text()
    # Same literal quoted matrix convention as test-ci-use-matrix.py.
    matrix = workflow.split("        use_flags:\n", 1)[1].split("    container:", 1)[0]
    cases = re.findall(r'^\s+- "([^"]*)"', matrix, re.MULTILINE)
    if not cases:
        raise SystemExit("Empty CI USE matrix")
    return cases


def usable_cases(repo: Path, version: str, abi: str) -> list[str]:
    ebuild = repo / f"sys-kernel/cachyos-sources/cachyos-sources-{version}.ebuild"
    source = ebuild.read_text()
    iuse = re.search(r'^IUSE="([^"]*)"', source, re.MULTILINE).group(1).split()
    available = {flag.lstrip("+-") for flag in iuse}
    return [case for case in matrix_cases(repo, abi)
            if not any(flag in case.split() and flag not in available
                       for flag in OPTIONAL_VARIANT_FLAGS)]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, default=ROOT)
    parser.add_argument("--versions-file", type=Path, required=True)
    parser.add_argument("--abi", choices=("glibc", "musl"), required=True)
    args = parser.parse_args()
    for version in args.versions_file.read_text().splitlines():
        for case in usable_cases(args.repo, version, args.abi):
            print(f"{version}|{case}")


if __name__ == "__main__":
    main()
