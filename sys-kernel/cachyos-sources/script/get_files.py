#!/usr/bin/env python3

from tempfile import TemporaryDirectory
import subprocess
from argparse import ArgumentParser


def clean_files(files_path: str, version: str):
    subprocess.call(["rm", "-rf", f"{files_path}/{version}"])


def get_patch(version: str, files_path: str, tmp_path: str) -> str:
    # create a tmp directory
    repo_name = "kernel-patches"
    repo_url = "https://github.com/CachyOS/kernel-patches.git"
    subprocess.call(
        ["git", "clone", "--depth", "1", repo_url, f"{tmp_path}/{repo_name}"]
    )
    # copy the patches to the files_path
    target_path = f"{files_path}/{version}"
    patch_version = ".".join(version.split(".")[:2])
    source_path = f"{tmp_path}/{repo_name}/{patch_version}"
    subprocess.call(["cp", "-r", source_path, target_path])
    commit_hash = (
        subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=f"{tmp_path}/{repo_name}"
        )
        .decode("utf-8")
        .strip()
    )
    with open(f"{target_path}/commit", "w") as f:
        f.write(commit_hash)
    return commit_hash


def get_config(version: str, files_path: str, tmp_path: str, lts: bool):
    # create a tmp directory
    repo_name = "linux-cachyos"
    repo_url = "https://github.com/CachyOS/linux-cachyos.git"
    subprocess.call(["git", "clone", repo_url, f"{tmp_path}/{repo_name}"])
    # copy the config to the files_path
    config_map = {
        #"": "bore-sched-ext",
        "deckify": "deckify",
        "bore": "bore",
        "hardened": "hardened",
        "eevdf": "eevdf",
        "rt-bore": "rt-bore",
        "sched-ext": "sched-ext",
        "echo": "echo",
        "bmq": "bmq",
    }
    if lts:
        config_map = {
            "lts": "lts",
        }
    for source, target in config_map.items():
        if source == "":
            source_dir_name = "linux-cachyos"
        else:
            source_dir_name = f"linux-cachyos-{source}"
        target_name = f"config-{target}"
        subprocess.call(
            [
                "cp",
                f"{tmp_path}/{repo_name}/{source_dir_name}/config",
                f"{files_path}/{version}/{target_name}",
            ]
        )
    subprocess.call(
        [
            "cp",
            f"{tmp_path}/{repo_name}/linux-cachyos/auto-cpu-optimization.sh",
            f"{files_path}/{version}/auto-cpu-optimization.sh",
        ]
    )


def diff_files(repo_path: str, previous_commit: str, lts: bool):
    if lts:
        diff_file = "linux-cachyos-lts/PKGBUILD"
    else:
        diff_file = "linux-cachyos/PKGBUILD"
    subprocess.call(
        ["git", "diff", previous_commit, "HEAD", "--", diff_file],
        cwd=repo_path,
    )
    subprocess.call(["git", "rev-parse", "HEAD"], cwd=repo_path)


def main(files_path: str, version: str, previous_commit: str, lts: bool):
    # get the latest version
    clean_files(files_path, version)
    with TemporaryDirectory() as tmp_path:
        get_patch(version, files_path, tmp_path)
        get_config(version, files_path, tmp_path, lts)
        repo_path = f"{tmp_path}/linux-cachyos"
        diff_files(repo_path, previous_commit, lts)


parser = ArgumentParser()
parser.add_argument("--files-path", type=str, default="./files")
parser.add_argument("--version", type=str, required=True)
parser.add_argument("--previous-commit", type=str, required=True)
parser.add_argument("--lts", action="store_true")
args = parser.parse_args()

main(args.files_path, args.version, args.previous_commit, args.lts)
