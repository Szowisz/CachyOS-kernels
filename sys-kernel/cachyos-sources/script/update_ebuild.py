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


# USE flag to upstream config directory mapping
USE_FLAG_CONFIG_MAPPING = {
    "bore": ["linux-cachyos", "linux-cachyos-bore"],
    "bmq": ["linux-cachyos-bmq"],
    "eevdf": ["linux-cachyos-eevdf"],
    "rt": ["linux-cachyos-rt-bore"],
    "rt-bore": ["linux-cachyos-rt-bore"],
    "hardened": ["linux-cachyos-hardened"],
    "deckify": ["linux-cachyos-deckify"],
}

# All upstream config directories to check
UPSTREAM_CONFIGS = [
    "linux-cachyos",
    "linux-cachyos-bmq",
    "linux-cachyos-bore",
    "linux-cachyos-deckify",
    "linux-cachyos-eevdf",
    "linux-cachyos-hardened",
    "linux-cachyos-rt-bore",
]


def parse_srcinfo_pkgver(content):
    """Parse pkgver from .SRCINFO content"""
    for line in content.split("\n"):
        line = line.strip()
        if line.startswith("pkgver = "):
            return line.split(" = ", 1)[1].strip()
    return None


def get_upstream_config_versions():
    """Fetch version info from upstream CachyOS/linux-cachyos repository"""
    versions = {}

    for config in UPSTREAM_CONFIGS:
        url = f"https://raw.githubusercontent.com/CachyOS/linux-cachyos/master/{config}/.SRCINFO"
        try:
            with urlopen(url) as response:
                content = response.read().decode("utf-8")
                pkgver = parse_srcinfo_pkgver(content)
                if pkgver:
                    versions[config] = pkgver
                    log(f"Upstream {config}: {pkgver}")
                else:
                    log(f"Could not parse pkgver from {config}/.SRCINFO", "WARN")
        except URLError as e:
            log(f"Failed to fetch {config}/.SRCINFO: {e}", "WARN")
        except Exception as e:
            log(f"Error processing {config}/.SRCINFO: {e}", "WARN")

    return versions


def parse_version_tuple(version_str):
    """Parse version string to tuple for comparison (e.g., '6.18.1' -> (6, 18, 1))"""
    # Clean version string, remove suffixes like -r1, -rc1
    clean_version = clean_version_helper(version_str)
    parts = clean_version.split(".")
    result = []
    for part in parts:
        try:
            result.append(int(part))
        except ValueError:
            result.append(0)
    # Pad to at least 3 elements
    while len(result) < 3:
        result.append(0)
    return tuple(result)


def compare_kernel_versions(target_version, config_version):
    """Compare kernel versions, return True if target_version <= config_version"""
    if config_version is None:
        return False

    target_tuple = parse_version_tuple(target_version)
    config_tuple = parse_version_tuple(config_version)

    return target_tuple <= config_tuple


def get_available_use_flags(target_version, upstream_versions):
    """Determine which USE flags are available based on upstream versions"""
    available = []
    unavailable = []

    for flag, configs in USE_FLAG_CONFIG_MAPPING.items():
        # Check if any associated config supports the target version
        is_available = any(
            compare_kernel_versions(target_version, upstream_versions.get(config))
            for config in configs
        )

        if is_available:
            available.append(flag)
        else:
            unavailable.append(flag)
            log(f"USE flag '{flag}' not available for version {target_version}", "INFO")

    return available, unavailable


def remove_use_flags_from_iuse(content, flags_to_remove):
    """Remove specified USE flags from IUSE declaration"""
    if not flags_to_remove:
        return content

    # Sort flags by length (descending) to remove longer flags first
    # This prevents "rt-bore" from being partially matched when removing "rt"
    flags_to_remove = sorted(flags_to_remove, key=len, reverse=True)

    # Build regex pattern to match IUSE block
    iuse_pattern = r'(IUSE="[^"]*")'
    match = re.search(iuse_pattern, content, re.DOTALL)

    if not match:
        log("Could not find IUSE declaration", "WARN")
        return content

    iuse_block = match.group(1)
    new_iuse_block = iuse_block

    for flag in flags_to_remove:
        # Remove flag with optional + prefix (for default enabled)
        # Use word boundaries to avoid partial matches
        # Pattern: optional +, the flag name, followed by whitespace or end quote
        new_iuse_block = re.sub(r'(?<![a-zA-Z0-9_-])\+?' + re.escape(flag) + r'(?=\s|")', '', new_iuse_block)

    # Clean up multiple spaces and empty lines
    new_iuse_block = re.sub(r'  +', ' ', new_iuse_block)
    new_iuse_block = re.sub(r'\t +', '\t', new_iuse_block)
    new_iuse_block = re.sub(r' +\n', '\n', new_iuse_block)

    return content.replace(iuse_block, new_iuse_block)


def remove_use_flags_from_src_prepare(content, flags_to_remove):
    """Replace 'use <flag>' with 'false' for unavailable USE flags in src_prepare"""
    if not flags_to_remove:
        return content

    for flag in flags_to_remove:
        # Replace "use <flag>" with "false"
        content = re.sub(r'\buse ' + re.escape(flag) + r'\b', 'false', content)

    return content


def remove_use_flags_from_required_use(content, flags_to_remove):
    """Remove specified USE flags from REQUIRED_USE declaration"""
    if not flags_to_remove:
        return content

    # Sort flags by length (descending) to process longer flags first
    flags_to_remove = sorted(flags_to_remove, key=len, reverse=True)

    # Find scheduler constraint line: ^^ ( bore bmq rt rt-bore eevdf )
    # Use a more flexible pattern that matches any content within ^^ ( ... )
    scheduler_pattern = r'(\^\^ \( )([a-z-]+(?: [a-z-]+)*)( \))'

    def replace_scheduler_constraint(match):
        prefix = match.group(1)
        flags_str = match.group(2)
        suffix = match.group(3)

        # Only process the first ^^ constraint (scheduler selection)
        scheduler_flags = flags_str.split()

        # Check if this looks like scheduler flags (contains bore, bmq, etc.)
        scheduler_keywords = {'bore', 'bmq', 'rt', 'rt-bore', 'eevdf'}
        if not any(f in scheduler_keywords for f in scheduler_flags):
            return match.group(0)  # Not the scheduler constraint, return unchanged

        # Remove unavailable flags
        available_flags = [f for f in scheduler_flags if f not in flags_to_remove]

        if available_flags:
            return prefix + ' '.join(available_flags) + suffix
        else:
            # All scheduler flags removed - this shouldn't happen in normal cases
            log("Warning: All scheduler flags would be removed!", "WARN")
            return match.group(0)

    # Replace only the first matching scheduler constraint
    new_content, count = re.subn(scheduler_pattern, replace_scheduler_constraint, content, count=1)
    if count > 0:
        # Extract what we replaced to for logging
        match = re.search(scheduler_pattern, new_content)
        if match:
            log(f"Updated scheduler constraint: ^^ ( {match.group(2)} )")
    content = new_content

    # Remove individual flag constraints (e.g., rt? ( ... ))
    for flag in flags_to_remove:
        # Remove lines like: rt? ( ^^ ( preempt_full preempt_lazy preempt_voluntary ) )
        content = re.sub(
            r'\n\t' + re.escape(flag) + r'\? \( [^\n]+\)',
            '',
            content
        )

    return content


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
    """Update commit-pinned SRC_URI variables in an ebuild."""
    if dry_run:
        log(f"DRY RUN: Would pin kernel-patches to {patches_commit[:12]}...")
        log(f"DRY RUN: Would pin linux-cachyos to {configs_commit[:12]}...")
        return True

    content = Path(ebuild_path).read_text()
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
        if count != 1:
            log(f"Could not find {variable} in ebuild", "ERROR")
            return False

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
    template_path, new_version, ebuild_dir, dry_run=False, force=False, lts=False,
    skip_version_check=False, upstream_versions=None, source_pkgrel=None
):
    """Copy and update ebuild for new version"""
    new_ebuild_name = f"cachyos-sources-{new_version}.ebuild"
    new_ebuild_path = Path(ebuild_dir) / new_ebuild_name

    if new_ebuild_path.exists() and not force:
        log(f"Ebuild {new_ebuild_name} already exists", "ERROR")
        return None
    elif new_ebuild_path.exists() and force:
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
            f"DRY RUN: Would copy and update ebuild with genpatches version {genpatches_version}",
            "INFO",
        )
        if source_pkgrel is not None:
            log(f"DRY RUN: Would use CachyOS source pkgrel {source_pkgrel}", "INFO")

        # Show which template USE flags would be removed. Missing variants are
        # never auto-added: they require explicit patch/config wiring and tests.
        if not skip_version_check and upstream_versions:
            _, unavailable_flags = get_available_use_flags(new_version, upstream_versions)
            if unavailable_flags:
                log(f"DRY RUN: Would remove USE flags: {', '.join(unavailable_flags)}", "INFO")
            else:
                log("DRY RUN: All template USE flags available for this version", "INFO")

        return new_ebuild_path

    # Copy template to new location (only if different files)
    if template_path != new_ebuild_path:
        shutil.copy2(template_path, new_ebuild_path)

    # Read content for updating
    with open(new_ebuild_path, "r") as f:
        content = f.read()

    # Extract template version for comparison
    template_version = extract_version_from_ebuild_name(template_path)

    # A Gentoo revision can track a variant-only CachyOS rebuild without a
    # new source tarball release. In that case, override the normal PR-based
    # mapping so the generated SRC_URI continues to use the published archive.
    if source_pkgrel is not None:
        content, count = re.subn(
            r'^CACHYOS_PR=.*$',
            f'CACHYOS_PR="{source_pkgrel}"',
            content,
            count=1,
            flags=re.MULTILINE,
        )
        if count != 1:
            log("Could not find CACHYOS_PR to override", "ERROR")
            return None
        log(f"Using CachyOS source pkgrel: {source_pkgrel}")

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

    # Update any version-specific comments or variables if needed
    # This could be extended for version-specific patches

    # Check upstream config versions and remove unavailable template USE flags.
    # Do not synthesize missing variants: each needs explicit SRC_URI/prepare wiring
    # plus an apply test against the exact source release.
    if not skip_version_check and upstream_versions:
        _, unavailable_flags = get_available_use_flags(new_version, upstream_versions)

        if unavailable_flags:
            log(f"Removing unavailable USE flags: {', '.join(unavailable_flags)}")
            content = remove_use_flags_from_iuse(content, unavailable_flags)
            content = remove_use_flags_from_required_use(content, unavailable_flags)
            content = remove_use_flags_from_src_prepare(content, unavailable_flags)

    # Write updated content back
    with open(new_ebuild_path, "w") as f:
        f.write(content)

    log(f"Updated genpatches version to: {genpatches_version}")
    return new_ebuild_path


def update_zfs_commit(ebuild_path, zfs_commit_hash, dry_run=False):
    """Update the ZFS_COMMIT variable in the ebuild"""
    if not zfs_commit_hash:
        log("No ZFS commit hash provided, skipping ZFS commit update", "WARN")
        return

    if dry_run:
        log(f"DRY RUN: Would update ZFS_COMMIT to {zfs_commit_hash[:12]}...")
        return

    try:
        with open(ebuild_path, "r") as f:
            content = f.read()

        # Replace existing ZFS_COMMIT line
        if re.search(r'^ZFS_COMMIT="[a-f0-9]{40}"$', content, re.MULTILINE):
            content = re.sub(
                r'^ZFS_COMMIT="[a-f0-9]{40}"$',
                f'ZFS_COMMIT="{zfs_commit_hash}"',
                content,
                flags=re.MULTILINE,
            )
            log(f"Updated ZFS_COMMIT to: {zfs_commit_hash[:12]}...")
        else:
            log("ZFS_COMMIT line not found in ebuild", "WARN")
            return

        with open(ebuild_path, "w") as f:
            f.write(content)

    except Exception as e:
        log(f"Error updating ZFS commit: {e}", "ERROR")


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
        help="Skip upstream config version check, keep all USE flags"
    )
    parser.add_argument(
        "--source-pkgrel",
        type=int,
        help="Override CachyOS source pkgrel for variant-only Gentoo revisions"
    )

    args = parser.parse_args()

    if args.source_pkgrel is not None and args.source_pkgrel < 1:
        log("--source-pkgrel must be a positive integer", "ERROR")
        sys.exit(1)

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

    # Fetch upstream config versions for USE flag availability check
    upstream_versions = None
    if not args.skip_version_check:
        log("Checking upstream config versions...")
        upstream_versions = get_upstream_config_versions()
        if not upstream_versions:
            log("Could not fetch upstream versions, skipping USE flag check", "WARN")
    else:
        log("Skipping upstream version check (--skip-version-check)")

    # Copy and update ebuild
    new_ebuild_path = copy_and_update_ebuild(
        template_ebuild, target_version, ebuild_dir, args.dry_run, args.force, args.lts,
        args.skip_version_check, upstream_versions, args.source_pkgrel
    )

    if not new_ebuild_path:
        sys.exit(1)

    patches_commit = get_repository_commit("kernel-patches")
    configs_commit = get_repository_commit("linux-cachyos")
    if not patches_commit or not configs_commit:
        log("Could not determine pinned upstream commits", "ERROR")
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
