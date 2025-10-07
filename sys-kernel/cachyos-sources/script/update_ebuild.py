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


def get_upstream_commit():
    """Get the latest commit hash from CachyOS/kernel-patches repository"""
    try:
        url = "https://api.github.com/repos/CachyOS/kernel-patches/commits?per_page=1"
        with urlopen(url) as response:
            data = json.loads(response.read().decode())

        if data and len(data) > 0:
            commit_sha = data[0]["sha"]
            log(f"Latest upstream commit: {commit_sha[:12]}...")
            return commit_sha

    except Exception as e:
        log(f"Error fetching upstream commit: {e}", "WARN")
        return None


def get_zfs_commit():
    """Get the ZFS commit hash from CachyOS linux-cachyos PKGBUILD"""
    try:
        url = "https://raw.githubusercontent.com/CachyOS/linux-cachyos/master/linux-cachyos/PKGBUILD"
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


def extract_previous_commit(ebuild_path):
    """Extract the previous commit hash from the ebuild file"""
    try:
        with open(ebuild_path, "r") as f:
            content = f.read()

        # Look for commit hash at the end of the file
        # Pattern: # <40-character hex hash>
        match = re.search(r"^# ([a-f0-9]{40})$", content, re.MULTILINE)
        if match:
            commit = match.group(1)
            log(f"Found previous commit: {commit[:12]}...")
            return commit
        else:
            log("No previous commit hash found in ebuild", "WARN")
            return None

    except Exception as e:
        log(f"Error reading ebuild: {e}", "ERROR")
        return None


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
        return new_ebuild_path

    # Copy template to new location (only if different files)
    if template_path != new_ebuild_path:
        shutil.copy2(template_path, new_ebuild_path)

    # Read content for updating
    with open(new_ebuild_path, "r") as f:
        content = f.read()

    # Extract template version for comparison
    template_version = extract_version_from_ebuild_name(template_path)

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
    zfs_commit = get_zfs_commit()
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

    # Write updated content back
    with open(new_ebuild_path, "w") as f:
        f.write(content)

    log(f"Updated genpatches version to: {genpatches_version}")
    return new_ebuild_path


def update_upstream_commit(ebuild_path, commit_hash, dry_run=False):
    """Update the upstream commit hash at the end of the ebuild"""
    if not commit_hash or dry_run:
        if dry_run:
            log(
                f"DRY RUN: Would update commit hash to {commit_hash[:12] if commit_hash else 'unknown'}..."
            )
        return

    try:
        with open(ebuild_path, "r") as f:
            content = f.read()

        # Replace existing commit hash or add new one
        if re.search(r"^# [a-f0-9]{40}$", content, re.MULTILINE):
            # Replace existing hash
            content = re.sub(
                r"^# [a-f0-9]{40}$", f"# {commit_hash}", content, flags=re.MULTILINE
            )
        else:
            # Add new hash at the end
            if not content.endswith("\n"):
                content += "\n"
            content += f"\n# {commit_hash}\n"

        with open(ebuild_path, "w") as f:
            f.write(content)

        log(f"Updated upstream commit to: {commit_hash[:12]}...")

    except Exception as e:
        log(f"Error updating commit hash: {e}", "ERROR")


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


def run_get_files(version, previous_commit, files_path, lts=False, dry_run=False):
    """Run the get_files.py script and return the new commit hash"""
    if dry_run:
        log("DRY RUN: Would run get_files.py", "INFO")
        return True, None

    script_dir = Path(__file__).parent
    get_files_script = script_dir / "get_files.py"

    if not get_files_script.exists():
        log(f"get_files.py not found at {get_files_script}", "ERROR")
        return False, None

    cmd = [
        sys.executable,
        str(get_files_script),
        "--version",
        version,
        "--files-path",
        files_path,
    ]

    if previous_commit:
        cmd.extend(["--previous-commit", previous_commit])
    else:
        # Use a reasonable fallback
        cmd.extend(["--previous-commit", "HEAD~1"])

    if lts:
        cmd.append("--lts")

    log(f"Running: {' '.join(cmd)}")

    try:
        result = subprocess.run(cmd, check=True, capture_output=True, text=True)
        log("get_files.py completed successfully")

        # Extract the new commit hash from stdout (last line should be the commit hash)
        new_commit_hash = None
        if result.stdout:
            lines = result.stdout.strip().split("\n")
            # The commit hash should be the last line and be 40 characters long
            if lines and re.match(r"^[a-f0-9]{40}$", lines[-1].strip()):
                new_commit_hash = lines[-1].strip()
                log(f"New commit hash from get_files.py: {new_commit_hash[:12]}...")
            print("STDOUT:", result.stdout)

        return True, new_commit_hash
    except subprocess.CalledProcessError as e:
        log(f"get_files.py failed: {e}", "ERROR")
        if e.stdout:
            print("STDOUT:", e.stdout)
        if e.stderr:
            print("STDERR:", e.stderr)
        return False, None


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
    parser.add_argument(
        "--previous-commit",
        type=str,
        help="Previous commit hash for diff (auto-detect if not provided)",
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
        "--files-path", type=str, default="./files", help="Path to files directory"
    )
    parser.add_argument(
        "--force", action="store_true", help="Force overwrite existing ebuild"
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
    template_ebuild = find_latest_ebuild(ebuild_dir, target_version)
    if not template_ebuild:
        sys.exit(1)

    # Get previous commit
    previous_commit = args.previous_commit
    if not previous_commit:
        previous_commit = extract_previous_commit(template_ebuild)

    if not previous_commit:
        log("Could not determine previous commit", "WARN")
        # Continue anyway, get_files.py might handle this

    # Copy and update ebuild
    new_ebuild_path = copy_and_update_ebuild(
        template_ebuild, target_version, ebuild_dir, args.dry_run, args.force, args.lts
    )

    if not new_ebuild_path:
        sys.exit(1)

    # Run get_files.py
    success, new_commit_hash = run_get_files(
        target_version, previous_commit, args.files_path, args.lts, args.dry_run
    )

    if not success:
        log("get_files.py failed, but continuing...", "WARN")

    # Use the new commit hash from get_files.py if available, otherwise fallback to upstream
    if new_commit_hash:
        update_upstream_commit(new_ebuild_path, new_commit_hash, args.dry_run)
    else:
        upstream_commit = get_upstream_commit()
        if upstream_commit:
            update_upstream_commit(new_ebuild_path, upstream_commit, args.dry_run)

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
