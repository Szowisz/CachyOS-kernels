#!/usr/bin/env python3

import os
import re
import sys
import json
import shutil
import subprocess
from argparse import ArgumentParser
from pathlib import Path
from tempfile import TemporaryDirectory
from urllib.request import urlopen
from urllib.error import URLError


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


def get_genpatches_version_from_template(template_ebuild_path, template_version, new_version):
    """Get genpatches version from template ebuild, increment by patch version difference or reset to 1 for major version change"""
    try:
        with open(template_ebuild_path, 'r') as f:
            content = f.read()
            
        # Find K_GENPATCHES_VER line
        match = re.search(r'K_GENPATCHES_VER="(\d+)"', content)
        if not match:
            log("Could not find K_GENPATCHES_VER in template, using default", "WARN")
            return "1"
            
        old_genpatches_version = int(match.group(1))
        
        # Parse versions to compare major.minor and patch
        template_parts = template_version.split('.')
        new_parts = new_version.split('.')
        
        # Ensure we have at least major.minor.patch
        if len(template_parts) >= 3 and len(new_parts) >= 3:
            template_major_minor = f"{template_parts[0]}.{template_parts[1]}"
            new_major_minor = f"{new_parts[0]}.{new_parts[1]}"
            
            if template_major_minor != new_major_minor:
                # Major version change, reset to 1
                log(f"Major version change ({template_major_minor} -> {new_major_minor}), resetting genpatches version to 1")
                return "1"
            else:
                # Same major version, increment by patch version difference
                template_patch = int(template_parts[2])
                new_patch = int(new_parts[2])
                patch_diff = new_patch - template_patch
                
                if patch_diff <= 0:
                    # If new patch version is not higher, just increment by 1
                    new_genpatches_version = old_genpatches_version + 1
                    log(f"Patch version not higher, incrementing genpatches version: {old_genpatches_version} -> {new_genpatches_version}")
                else:
                    # Increment by patch version difference
                    new_genpatches_version = old_genpatches_version + patch_diff
                    log(f"Same major version, incrementing genpatches version by patch diff ({patch_diff}): {old_genpatches_version} -> {new_genpatches_version}")
                
                return str(new_genpatches_version)
        else:
            log("Could not parse version numbers properly, using simple increment", "WARN")
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


def parse_version(version_str):
    """Parse version string for proper sorting"""
    # Extract version from filename like cachyos-sources-6.16.9.ebuild
    match = re.search(r'cachyos-sources-(\d+)\.(\d+)\.(\d+)(?:\.(\d+))?(?:-r(\d+))?\.ebuild', version_str)
    if match:
        major, minor, patch, micro, revision = match.groups()
        return (
            int(major),
            int(minor), 
            int(patch),
            int(micro) if micro else 0,
            int(revision) if revision else 0
        )
    return (0, 0, 0, 0, 0)


def find_latest_ebuild(ebuild_dir):
    """Find the latest existing ebuild to use as template"""
    ebuild_files = list(Path(ebuild_dir).glob("cachyos-sources-*.ebuild"))
    
    if not ebuild_files:
        log("No existing ebuilds found", "ERROR")
        return None
        
    # Sort by parsed version numbers
    latest = max(ebuild_files, key=lambda x: parse_version(x.name))
    log(f"Using template: {latest.name}")
    return latest


def extract_previous_commit(ebuild_path):
    """Extract the previous commit hash from the ebuild file"""
    try:
        with open(ebuild_path, 'r') as f:
            content = f.read()
            
        # Look for commit hash at the end of the file
        # Pattern: # <40-character hex hash>
        match = re.search(r'^# ([a-f0-9]{40})$', content, re.MULTILINE)
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
    match = re.search(r'cachyos-sources-(.+)\.ebuild', filename)
    return match.group(1) if match else None


def copy_and_update_ebuild(template_path, new_version, ebuild_dir, dry_run=False):
    """Copy and update ebuild for new version"""
    new_ebuild_name = f"cachyos-sources-{new_version}.ebuild"
    new_ebuild_path = Path(ebuild_dir) / new_ebuild_name
    
    if new_ebuild_path.exists():
        log(f"Ebuild {new_ebuild_name} already exists", "ERROR")
        return None
        
    log(f"Creating new ebuild: {new_ebuild_name}")
    
    if dry_run:
        # Still calculate what genpatches version would be used
        template_version = extract_version_from_ebuild_name(template_path)
        genpatches_version = get_genpatches_version_from_template(template_path, template_version, new_version)
        log(f"DRY RUN: Would copy and update ebuild with genpatches version {genpatches_version}", "INFO")
        return new_ebuild_path
        
    # Copy template to new location
    shutil.copy2(template_path, new_ebuild_path)
    
    # Read content for updating
    with open(new_ebuild_path, 'r') as f:
        content = f.read()
    
    # Extract template version for comparison
    template_version = extract_version_from_ebuild_name(template_path)
    
    # Update genpatches version (increment from template or reset for major version)
    genpatches_version = get_genpatches_version_from_template(template_path, template_version, new_version)
    content = re.sub(
        r'K_GENPATCHES_VER=".*"',
        f'K_GENPATCHES_VER="{genpatches_version}"',
        content
    )
    
    # Update any version-specific comments or variables if needed
    # This could be extended for version-specific patches
    
    # Write updated content back
    with open(new_ebuild_path, 'w') as f:
        f.write(content)
        
    log(f"Updated genpatches version to: {genpatches_version}")
    return new_ebuild_path


def update_upstream_commit(ebuild_path, commit_hash, dry_run=False):
    """Update the upstream commit hash at the end of the ebuild"""
    if not commit_hash or dry_run:
        if dry_run:
            log(f"DRY RUN: Would update commit hash to {commit_hash[:12] if commit_hash else 'unknown'}...")
        return
        
    try:
        with open(ebuild_path, 'r') as f:
            content = f.read()
            
        # Replace existing commit hash or add new one
        if re.search(r'^# [a-f0-9]{40}$', content, re.MULTILINE):
            # Replace existing hash
            content = re.sub(
                r'^# [a-f0-9]{40}$',
                f'# {commit_hash}',
                content,
                flags=re.MULTILINE
            )
        else:
            # Add new hash at the end
            if not content.endswith('\n'):
                content += '\n'
            content += f'\n# {commit_hash}\n'
            
        with open(ebuild_path, 'w') as f:
            f.write(content)
            
        log(f"Updated upstream commit to: {commit_hash[:12]}...")
        
    except Exception as e:
        log(f"Error updating commit hash: {e}", "ERROR")


def run_get_files(version, previous_commit, files_path, lts=False, dry_run=False):
    """Run the get_files.py script"""
    if dry_run:
        log("DRY RUN: Would run get_files.py", "INFO")
        return True
        
    script_dir = Path(__file__).parent
    get_files_script = script_dir / "get_files.py"
    
    if not get_files_script.exists():
        log(f"get_files.py not found at {get_files_script}", "ERROR")
        return False
        
    cmd = [
        sys.executable, str(get_files_script),
        "--version", version,
        "--files-path", files_path
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
        if result.stdout:
            print("STDOUT:", result.stdout)
        return True
    except subprocess.CalledProcessError as e:
        log(f"get_files.py failed: {e}", "ERROR")
        if e.stdout:
            print("STDOUT:", e.stdout)
        if e.stderr:
            print("STDERR:", e.stderr)
        return False


def update_manifest(ebuild_path, dry_run=False):
    """Run ebuild manifest to update the Manifest file"""
    if dry_run:
        log("DRY RUN: Would run ebuild manifest", "INFO")
        return True
        
    log("Updating manifest...")
    
    try:
        cmd = ["ebuild", str(ebuild_path), "manifest"]
        result = subprocess.run(cmd, check=True, capture_output=True, text=True)
        log("Manifest updated successfully")
        return True
    except subprocess.CalledProcessError as e:
        log(f"Manifest update failed: {e}", "ERROR")
        if e.stderr:
            print("STDERR:", e.stderr)
        return False
    except FileNotFoundError:
        log("ebuild command not found. Please ensure portage is installed.", "ERROR")
        return False


def validate_version(version):
    """Validate kernel version format"""
    pattern = r'^\d+\.\d+\.\d+(?:\.\d+)?(?:-rc\d+)?$'
    return re.match(pattern, version) is not None


def main():
    parser = ArgumentParser(description="Update CachyOS kernel ebuild")
    parser.add_argument("--version", type=str, help="Specific kernel version to create (auto-detect if not provided)")
    parser.add_argument("--previous-commit", type=str, help="Previous commit hash for diff (auto-detect if not provided)")
    parser.add_argument("--lts", action="store_true", help="LTS kernel flag")
    parser.add_argument("--no-manifest", action="store_true", help="Skip manifest generation")
    parser.add_argument("--dry-run", action="store_true", help="Show what would be done without making changes")
    parser.add_argument("--files-path", type=str, default="./files", help="Path to files directory")
    
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
    
    if new_ebuild_path.exists() and not args.dry_run:
        log(f"Ebuild {new_ebuild_name} already exists", "ERROR")
        sys.exit(1)
    
    # Find template ebuild
    template_ebuild = find_latest_ebuild(ebuild_dir)
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
        template_ebuild, target_version, ebuild_dir, args.dry_run
    )
    
    if not new_ebuild_path:
        sys.exit(1)
    
    # Run get_files.py
    success = run_get_files(
        target_version, previous_commit, args.files_path, args.lts, args.dry_run
    )
    
    if not success:
        log("get_files.py failed, but continuing...", "WARN")
    
    # Get and update upstream commit
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
        log(f"  2. Test build: emerge =sys-kernel/cachyos-sources-{target_version}", "INFO")
        log("  3. Commit changes if everything looks good", "INFO")


if __name__ == "__main__":
    main()