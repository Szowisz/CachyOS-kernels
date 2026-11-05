#!/usr/bin/env python3

import json
import re
import shutil
import subprocess
import sys
from argparse import ArgumentParser
from pathlib import Path
from urllib.error import URLError
from urllib.request import urlopen


def log(message, level="INFO"):
    """Simple logging function"""
    print(f"[{level}] {message}")


# PKGBUILD option patterns each official package must still carry. A mismatch
# means upstream packaging changed and the ebuild USE surface needs review.
OFFICIAL_PACKAGE_PATTERNS = {
    "linux-cachyos": ("_cpusched:=cachyos",),
    "linux-cachyos-bore": ("_cpusched:=bore", "sched/0001-bore-cachy.patch"),
    "linux-cachyos-bmq": ("_cpusched:=bmq", "sched/0001-prjc-cachy.patch"),
    "linux-cachyos-deckify": (
        "_cpusched:=cachyos",
        "sched/0001-bore-cachy.patch",
        "misc/0001-acpi-call.patch",
        "misc/0001-handheld.patch",
    ),
    "linux-cachyos-eevdf": ("_cpusched:=eevdf",),
    "linux-cachyos-rt-bore": (
        "_cpusched:=rt-bore",
    ),
    "linux-cachyos-server": (
        "_cachy_config:=no",
        "_cpusched:=eevdf",
        "_HZ_ticks:=300",
        "_tickrate:=full",
        "_preempt:=lazy",
        "_hugepage:=madvise",
        "_use_llvm_lto:=none",
    ),
}

UPSTREAM_PACKAGES = [
    *OFFICIAL_PACKAGE_PATTERNS,
    "linux-cachyos-hardened",
    "linux-cachyos-lts",
]


def parse_srcinfo_pkgver(content):
    """Parse pkgver from .SRCINFO content."""
    for line in content.splitlines():
        line = line.strip()
        if line.startswith("pkgver = "):
            return line.split(" = ", 1)[1].strip()
    return None


def fetch_upstream_package_data(configs_commit):
    """Fetch package versions and PKGBUILDs from the commit pinned by generation."""
    versions = {}
    pkgbuilds = {}

    for package in UPSTREAM_PACKAGES:
        base_url = (
            "https://raw.githubusercontent.com/CachyOS/linux-cachyos/"
            f"{configs_commit}/{package}"
        )
        try:
            with urlopen(f"{base_url}/.SRCINFO") as response:
                pkgver = parse_srcinfo_pkgver(response.read().decode("utf-8"))
            with urlopen(f"{base_url}/PKGBUILD") as response:
                pkgbuild = response.read().decode("utf-8")
            if pkgver:
                versions[package] = pkgver
                pkgbuilds[package] = pkgbuild
                log(f"Upstream {package}: {pkgver}")
            else:
                log(f"Could not parse pkgver from {package}/.SRCINFO", "WARN")
        except URLError as e:
            log(f"Failed to fetch {package}: {e}", "WARN")
        except Exception as e:
            log(f"Error processing {package}: {e}", "WARN")

    return versions, pkgbuilds


def audit_official_package_inventory(
    target_version, upstream_versions, pkgbuilds, lts=False
):
    """Validate the explicit package-to-layer map against pinned PKGBUILDs."""
    clean_target = clean_version_helper(target_version)
    errors = []

    if lts:
        if upstream_versions.get("linux-cachyos-lts") != clean_target:
            errors.append(
                "linux-cachyos-lts does not target the requested LTS version"
            )
        elif "_cpusched:=cachyos" not in pkgbuilds.get("linux-cachyos-lts", ""):
            errors.append("linux-cachyos-lts: upstream scheduler default changed")
        return errors

    for package, patterns in OFFICIAL_PACKAGE_PATTERNS.items():
        if upstream_versions.get(package) != clean_target:
            continue
        pkgbuild = pkgbuilds.get(package, "")
        for pattern in patterns:
            if pattern not in pkgbuild:
                errors.append(f"{package}: upstream no longer matches: {pattern}")

    return errors


def report_feature_audit(errors, prefix=""):
    """Log deterministic feature audit results."""
    label = f"{prefix}: " if prefix else ""
    if not errors:
        log(f"{label}PKGBUILD options match")
        return True
    for error in errors:
        log(f"{label}{error}", "ERROR")
    return False


def get_latest_kernel_version():
    """Fetch the latest stable kernel version from kernel.org"""
    try:
        with urlopen("https://www.kernel.org/releases.json") as response:
            data = json.loads(response.read().decode())
            # Get the latest stable version
            for release in data["releases"]:
                if release["moniker"] == "stable":
                    version = release["version"]
                    log(f"Latest stable kernel version: {version}")
                    return version
    except URLError as e:
        log(f"Failed to fetch kernel version: {e}", "ERROR")
        return None
    except Exception as e:
        log(f"Error parsing kernel version: {e}", "ERROR")
        return None


def find_latest_ebuild_for_version_series(ebuild_dir, target_major_minor, exclude_version=None):
    """Find the latest ebuild for the same major.minor version series"""
    ebuild_files = list(Path(ebuild_dir).glob("cachyos-sources-*.ebuild"))
    
    if not ebuild_files:
        return None
    
    # Exclude the target version if specified
    if exclude_version:
        exclude_name = f"cachyos-sources-{exclude_version}.ebuild"
        ebuild_files = [f for f in ebuild_files if f.name != exclude_name]
    
    # Filter for same major.minor version
    matching_files = []
    for f in ebuild_files:
        version = extract_version_from_ebuild_name(f)
        if version:
            clean_version = clean_version_helper(version)
            version_parts = clean_version.split(".")
            if len(version_parts) >= 2:
                file_major_minor = f"{version_parts[0]}.{version_parts[1]}"
                if file_major_minor == target_major_minor:
                    matching_files.append(f)
    
    if not matching_files:
        return None
    
    # Return the latest one
    latest = max(matching_files, key=lambda x: parse_version(x.name))
    return latest


def clean_version_helper(version):
    """Helper function to clean version numbers"""
    # Extract only the numeric version part (e.g. "6.17.0" from "6.17.0-r3")
    match = re.match(r'^(\d+\.\d+\.\d+(?:\.\d+)?)', version)
    return match.group(1) if match else version


def get_genpatches_version_from_template(
    template_ebuild_path, template_version, new_version, ebuild_dir=None, lts=False
):
    """Get genpatches version from template ebuild, increment by patch version difference or reset to 1 for major version change"""
    try:
        with open(template_ebuild_path, "r") as f:
            content = f.read()

        # Find K_GENPATCHES_VER line
        match = re.search(r'K_GENPATCHES_VER="(\d+)"', content)
        if not match:
            log("Could not find K_GENPATCHES_VER in template, using default", "WARN")
            return "1"

        old_genpatches_version = int(match.group(1))

        # Parse versions to compare major.minor and patch
        # Extract clean version numbers, removing any suffixes like -r1, -rc1, etc.
        clean_template_version = clean_version_helper(template_version)
        clean_new_version = clean_version_helper(new_version)

        # Gentoo revision-only bumps keep the same upstream kernel tarball, so the
        # genpatches version should stay unchanged.
        if clean_template_version == clean_new_version:
            log(
                f"Revision-only bump ({template_version} -> {new_version}), keeping genpatches version: {old_genpatches_version}"
            )
            return str(old_genpatches_version)

        template_parts = clean_template_version.split(".")
        new_parts = clean_new_version.split(".")

        # Ensure we have at least major.minor.patch
        if len(template_parts) >= 3 and len(new_parts) >= 3:
            template_major_minor = f"{template_parts[0]}.{template_parts[1]}"
            new_major_minor = f"{new_parts[0]}.{new_parts[1]}"

            if template_major_minor != new_major_minor:
                if lts and ebuild_dir:
                    # For LTS versions, try to find the latest ebuild in the same version series
                    log(f"LTS version update: looking for latest ebuild in {new_major_minor} series")
                    latest_ebuild = find_latest_ebuild_for_version_series(ebuild_dir, new_major_minor, new_version)
                    if latest_ebuild:
                        log(f"Found latest ebuild for {new_major_minor} series: {latest_ebuild.name}")
                        # Use this ebuild as the new template
                        latest_version = extract_version_from_ebuild_name(latest_ebuild)
                        if latest_version:
                            with open(latest_ebuild, "r") as f:
                                latest_content = f.read()
                            match = re.search(r'K_GENPATCHES_VER="(\d+)"', latest_content)
                            if match:
                                latest_genpatches_version = int(match.group(1))
                                # Calculate patch version difference for increment
                                latest_clean_version = clean_version_helper(latest_version)
                                latest_parts = latest_clean_version.split(".")
                                if len(latest_parts) >= 3:
                                    latest_patch = int(latest_parts[2])
                                    new_patch = int(new_parts[2])
                                    patch_diff = new_patch - latest_patch
                                    
                                    if patch_diff <= 0:
                                        new_genpatches_version = latest_genpatches_version + 1
                                        log(f"Patch version not higher, incrementing genpatches version: {latest_genpatches_version} -> {new_genpatches_version}")
                                    else:
                                        new_genpatches_version = latest_genpatches_version + patch_diff
                                        log(f"Same major version, incrementing genpatches version by patch diff ({patch_diff}): {latest_genpatches_version} -> {new_genpatches_version}")
                                    
                                    return str(new_genpatches_version)
                    
                    log(f"Could not find existing ebuild for {new_major_minor} series, resetting genpatches version to 1")
                
                # Major version change, reset to 1
                log(
                    f"Major version change ({template_major_minor} -> {new_major_minor}), resetting genpatches version to 1"
                )
                return "1"
            else:
                # Same major version, increment by patch version difference
                template_patch = int(template_parts[2])
                new_patch = int(new_parts[2])
                patch_diff = new_patch - template_patch

                if patch_diff <= 0:
                    # If new patch version is not higher, just increment by 1
                    new_genpatches_version = old_genpatches_version + 1
                    log(
                        f"Patch version not higher, incrementing genpatches version: {old_genpatches_version} -> {new_genpatches_version}"
                    )
                else:
                    # Increment by patch version difference
                    new_genpatches_version = old_genpatches_version + patch_diff
                    log(
                        f"Same major version, incrementing genpatches version by patch diff ({patch_diff}): {old_genpatches_version} -> {new_genpatches_version}"
                    )

                return str(new_genpatches_version)
        else:
            log(
                "Could not parse version numbers properly, using simple increment",
                "WARN",
            )
            return str(old_genpatches_version + 1)

    except Exception as e:
        log(f"Error reading genpatches version from template: {e}", "WARN")
        return "1"


def get_repository_commit(repository):
    """Get the latest commit hash from a CachyOS GitHub repository."""
    try:
        url = f"https://api.github.com/repos/CachyOS/{repository}/commits?per_page=1"
        with urlopen(url) as response:
            data = json.loads(response.read().decode())
        if data:
            commit_sha = data[0]["sha"]
            log(f"Latest {repository} commit: {commit_sha[:12]}...")
            return commit_sha
    except Exception as e:
        log(f"Error fetching {repository} commit: {e}", "WARN")
        return None


def update_upstream_commits(ebuild_path, patches_commit, configs_commit, dry_run=False):
    """Update or add commit-pinned SRC_URI variables in an ebuild."""
    if dry_run:
        log(f"DRY RUN: Would pin kernel-patches to {patches_commit[:12]}...")
        log(f"DRY RUN: Would pin linux-cachyos to {configs_commit[:12]}...")
        return True

    content = Path(ebuild_path).read_text()
    missing = []
    for variable, commit in {
        "CACHYOS_PATCHES_COMMIT": patches_commit,
        "CACHYOS_CONFIGS_COMMIT": configs_commit,
    }.items():
        content, count = re.subn(
            rf'^{variable}="[a-f0-9]{{40}}"$',
            f'{variable}="{commit}"',
            content,
            count=1,
            flags=re.MULTILINE,
        )
        if count == 0:
            missing.append(f'{variable}="{commit}"')

    if missing:
        marker = 'K_NOSETEXTRAVERSION="1"\n'
        if marker not in content:
            log("Could not find insertion point for upstream commit pins", "ERROR")
            return False
        content = content.replace(
            marker,
            marker + "\n# Pin patch and config inputs so Manifest checks cover exact upstream bytes.\n"
            + "\n".join(missing) + "\n",
            1,
        )

    Path(ebuild_path).write_text(content)
    return True


def get_zfs_commit(lts=False):
    """Get the ZFS commit hash from CachyOS linux-cachyos PKGBUILD"""
    try:
        # Use linux-cachyos-lts for LTS versions, linux-cachyos for regular versions
        if lts:
            url = "https://raw.githubusercontent.com/CachyOS/linux-cachyos/master/linux-cachyos-lts/PKGBUILD"
            log("Fetching ZFS commit from linux-cachyos-lts/PKGBUILD")
        else:
            url = "https://raw.githubusercontent.com/CachyOS/linux-cachyos/master/linux-cachyos/PKGBUILD"
            log("Fetching ZFS commit from linux-cachyos/PKGBUILD")

        with urlopen(url) as response:
            content = response.read().decode("utf-8")

        # Look for the ZFS commit in the source array
        # Format: source+=("git+https://github.com/cachyos/zfs.git#commit=<hash>")
        match = re.search(
            r"git\+https://github\.com/cachyos/zfs\.git#commit=([a-f0-9]{40})", content
        )
        if match:
            commit_sha = match.group(1)
            log(f"ZFS commit from PKGBUILD: {commit_sha[:12]}...")
            return commit_sha
        else:
            log("ZFS commit not found in PKGBUILD", "WARN")
            return None

    except Exception as e:
        log(f"Error fetching ZFS commit from PKGBUILD: {e}", "WARN")
        return None


def parse_version(version_str):
    """Parse version string for proper sorting"""
    # Extract version from filename like cachyos-sources-6.16.9.ebuild
    match = re.search(
        r"cachyos-sources-(\d+)\.(\d+)\.(\d+)(?:\.(\d+))?(?:-r(\d+))?\.ebuild",
        version_str,
    )
    if match:
        major, minor, patch, micro, revision = match.groups()
        return (
            int(major),
            int(minor),
            int(patch),
            int(micro) if micro else 0,
            int(revision) if revision else 0,
        )
    return (0, 0, 0, 0, 0)


def find_latest_ebuild(ebuild_dir, exclude_version=None):
    """Find the latest existing ebuild to use as template, excluding target version"""
    ebuild_files = list(Path(ebuild_dir).glob("cachyos-sources-*.ebuild"))

    if not ebuild_files:
        log("No existing ebuilds found", "ERROR")
        return None

    # Exclude the target version if specified
    if exclude_version:
        exclude_name = f"cachyos-sources-{exclude_version}.ebuild"
        ebuild_files = [f for f in ebuild_files if f.name != exclude_name]

    if not ebuild_files:
        log("No suitable template ebuilds found after exclusion", "ERROR")
        return None

    # Sort by parsed version numbers
    latest = max(ebuild_files, key=lambda x: parse_version(x.name))
    log(f"Using template: {latest.name}")
    return latest


def extract_version_from_ebuild_name(ebuild_path):
    """Extract version from ebuild filename"""
    filename = Path(ebuild_path).name
    match = re.search(r"cachyos-sources-(.+)\.ebuild", filename)
    return match.group(1) if match else None


def copy_and_update_ebuild(
    template_path, new_version, ebuild_dir, dry_run=False, force=False, lts=False
):
    """Copy and update ebuild for new version"""
    new_ebuild_name = f"cachyos-sources-{new_version}.ebuild"
    new_ebuild_path = Path(ebuild_dir) / new_ebuild_name

    target_existed = new_ebuild_path.exists()
    if target_existed and not force:
        log(f"Ebuild {new_ebuild_name} already exists", "ERROR")
        return None
    elif target_existed and force:
        log(
            f"Ebuild {new_ebuild_name} already exists, but --force specified, overwriting",
            "WARN",
        )

    log(f"Creating new ebuild: {new_ebuild_name}")

    if dry_run:
        # Still calculate what genpatches version would be used
        template_version = extract_version_from_ebuild_name(template_path)
        genpatches_version = get_genpatches_version_from_template(
            template_path, template_version, new_version, ebuild_dir, lts
        )
        log(
            f"DRY RUN: Would generate an ebuild with genpatches version {genpatches_version}",
            "INFO",
        )
        return new_ebuild_path

    # Build the candidate entirely in memory; an existing --force target stays
    # intact if any transformation fails.
    content = Path(template_path).read_text()

    # Extract template version for comparison
    template_version = extract_version_from_ebuild_name(template_path)

    # CachyOS pkgrel is encoded by the Gentoo revision.
    content, count = re.subn(
        r'^CACHYOS_PR=.*$',
        'CACHYOS_PR="$(( ${PR#r} + 1 ))"',
        content,
        count=1,
        flags=re.MULTILINE,
    )
    if count != 1:
        log("Could not normalize CACHYOS_PR from the template", "ERROR")
        return None

    # Update genpatches version (increment from template or reset for major version)
    genpatches_version = get_genpatches_version_from_template(
        template_path, template_version, new_version, ebuild_dir, lts
    )
    # Handle both commented and uncommented K_GENPATCHES_VER lines
    if re.search(r'#K_GENPATCHES_VER=".*"', content):
        content = re.sub(
            r'#K_GENPATCHES_VER=".*"',
            f'K_GENPATCHES_VER="{genpatches_version}"',
            content,
        )
    else:
        content = re.sub(
            r'K_GENPATCHES_VER=".*"',
            f'K_GENPATCHES_VER="{genpatches_version}"',
            content,
        )

    # Update ZFS commit to latest
    zfs_commit = get_zfs_commit(lts=lts)
    if zfs_commit and re.search(r'^ZFS_COMMIT="[a-f0-9]{40}"$', content, re.MULTILINE):
        content = re.sub(
            r'^ZFS_COMMIT="[a-f0-9]{40}"$',
            f'ZFS_COMMIT="{zfs_commit}"',
            content,
            flags=re.MULTILINE,
        )
        log(f"Updated ZFS_COMMIT to: {zfs_commit[:12]}...")

    # Write only after every transformation succeeds.
    with open(new_ebuild_path, "w") as f:
        f.write(content)

    log(f"Updated genpatches version to: {genpatches_version}")
    return new_ebuild_path


def check_sudo_available():
    """Check if sudo is available on the system"""
    try:
        result = subprocess.run(['which', 'sudo'], capture_output=True, text=True, check=False)
        return result.returncode == 0
    except Exception:
        return False


def update_manifest(ebuild_path, dry_run=False):
    """Run ebuild manifest to update the Manifest file"""
    if dry_run:
        log("DRY RUN: Would run ebuild manifest", "INFO")
        return True

    log("Updating manifest...")

    # First try without sudo
    try:
        cmd = ["ebuild", str(ebuild_path), "manifest"]
        result = subprocess.run(cmd, check=True, capture_output=True, text=True)
        log("Manifest updated successfully")
        return True
    except subprocess.CalledProcessError as e:
        # If failed and sudo is available, try with sudo
        if check_sudo_available():
            log("First attempt failed, trying with sudo...")
            try:
                cmd = ["sudo", "ebuild", str(ebuild_path), "manifest"]
                result = subprocess.run(cmd, check=True, capture_output=True, text=True)
                log("Manifest updated successfully with sudo")
                return True
            except subprocess.CalledProcessError as e2:
                log(f"Manifest update failed even with sudo: {e2}", "ERROR")
                if e2.stderr:
                    print("STDERR:", e2.stderr)
                return False
        else:
            log(f"Manifest update failed: {e}", "ERROR")
            if e.stderr:
                print("STDERR:", e.stderr)
            return False
    except FileNotFoundError:
        log("ebuild command not found. Please ensure portage is installed.", "ERROR")
        return False


def validate_version(version):
    """Validate kernel version format, ignoring revision suffixes"""
    # Extract just the version part, ignore revision suffixes like -r1, -rc1, etc.
    # Accept formats like: 6.17.0, 6.17.0-r3, 6.17.0-rc1, 6.17.0.1-r2
    pattern = r"^\d+\.\d+\.\d+(?:\.\d+)?(?:-(?:rc\d+|r\d+))?$"
    return re.match(pattern, version) is not None


def main():
    parser = ArgumentParser(description="Update CachyOS kernel ebuild")
    parser.add_argument(
        "--version",
        type=str,
        help="Specific kernel version to create (auto-detect if not provided)",
    )
    parser.add_argument("--lts", action="store_true", help="LTS kernel flag")
    parser.add_argument(
        "--no-manifest", action="store_true", help="Skip manifest generation"
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would be done without making changes",
    )
    parser.add_argument(
        "--force", action="store_true", help="Force overwrite existing ebuild"
    )
    parser.add_argument(
        "--skip-version-check",
        action="store_true",
        help="Skip the upstream PKGBUILD option check"
    )
    args = parser.parse_args()

    # Determine ebuild directory
    script_dir = Path(__file__).parent
    ebuild_dir = script_dir.parent

    log(f"Working in directory: {ebuild_dir}")

    # Get target version
    if args.version:
        target_version = args.version
        if not validate_version(target_version):
            log(f"Invalid version format: {target_version}", "ERROR")
            sys.exit(1)
    else:
        target_version = get_latest_kernel_version()
        if not target_version:
            log("Failed to determine target version", "ERROR")
            sys.exit(1)

    log(f"Target version: {target_version}")

    # Check if ebuild already exists
    new_ebuild_name = f"cachyos-sources-{target_version}.ebuild"
    new_ebuild_path = ebuild_dir / new_ebuild_name

    if new_ebuild_path.exists() and not args.dry_run and not args.force:
        log(f"Ebuild {new_ebuild_name} already exists", "ERROR")
        sys.exit(1)

    # Find template ebuild (excluding target version)
    # For LTS versions, prefer finding the latest ebuild in the same version series
    if args.lts:
        clean_target_version = clean_version_helper(target_version)
        target_parts = clean_target_version.split(".")
        if len(target_parts) >= 2:
            target_major_minor = f"{target_parts[0]}.{target_parts[1]}"
            template_ebuild = find_latest_ebuild_for_version_series(ebuild_dir, target_major_minor, target_version)
            if not template_ebuild:
                log(f"No existing ebuild found for {target_major_minor} series, falling back to latest ebuild", "WARN")
                template_ebuild = find_latest_ebuild(ebuild_dir, target_version)
        else:
            template_ebuild = find_latest_ebuild(ebuild_dir, target_version)
    else:
        template_ebuild = find_latest_ebuild(ebuild_dir, target_version)
    
    if not template_ebuild:
        sys.exit(1)

    patches_commit = get_repository_commit("kernel-patches")
    configs_commit = get_repository_commit("linux-cachyos")
    if not patches_commit or not configs_commit:
        log("Could not determine pinned upstream commits", "ERROR")
        sys.exit(1)

    if not args.skip_version_check:
        log("Checking upstream PKGBUILD options...")
        upstream_versions, pkgbuilds = fetch_upstream_package_data(configs_commit)
        if len(upstream_versions) != len(UPSTREAM_PACKAGES):
            missing = sorted(set(UPSTREAM_PACKAGES) - set(upstream_versions))
            log("Could not fetch upstream packages: " + ", ".join(missing), "ERROR")
            sys.exit(1)

        upstream_errors = audit_official_package_inventory(
            target_version, upstream_versions, pkgbuilds, args.lts
        )
        if not report_feature_audit(upstream_errors, "UPSTREAM"):
            sys.exit(1)
    else:
        log("Skipping upstream PKGBUILD option check (--skip-version-check)")

    new_ebuild_path = copy_and_update_ebuild(
        template_ebuild, target_version, ebuild_dir, args.dry_run, args.force, args.lts
    )

    if not new_ebuild_path:
        sys.exit(1)

    if not update_upstream_commits(
        new_ebuild_path, patches_commit, configs_commit, args.dry_run
    ):
        sys.exit(1)

    # Update manifest
    if not args.no_manifest:
        if not update_manifest(new_ebuild_path, args.dry_run):
            log("Manifest update failed, but ebuild was created", "WARN")

    if args.dry_run:
        log("DRY RUN completed - no changes made", "INFO")
    else:
        log(f"Successfully created {new_ebuild_name}", "SUCCESS")
        log("Next steps:", "INFO")
        log(f"  1. Review the new ebuild: {new_ebuild_path}", "INFO")
        log(
            f"  2. Test build: emerge =sys-kernel/cachyos-sources-{target_version}",
            "INFO",
        )
        log("  3. Commit changes if everything looks good", "INFO")


if __name__ == "__main__":
    main()
