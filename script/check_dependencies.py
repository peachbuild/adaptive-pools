#!/usr/bin/env python3
"""Check pinned dependency checkouts and their recursively pinned children. No network."""
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def git(path, *args):
    return subprocess.check_output(
        ["git", "-C", str(path), *args], stderr=subprocess.PIPE
    )


def check_checkout(path, revision):
    if not (path / ".git").exists():
        raise RuntimeError(f"{path.relative_to(ROOT)}: missing checkout; initialize submodules")
    actual = git(path, "rev-parse", "HEAD").decode().strip()
    if actual != revision:
        raise RuntimeError(f"{path.relative_to(ROOT)}: expected {revision}, found {actual}")
    # Verify every tracked file, including deleted files and staged changes.
    # Ignore generated artifacts, but reject extra Solidity sources below.
    if git(path, "status", "--porcelain", "--untracked-files=no").strip():
        raise RuntimeError(f"{path.relative_to(ROOT)}: tracked files or nested revisions were modified")
    records = git(path, "ls-tree", "-rz", "HEAD").split(b"\0")
    tracked = set()
    children = []
    for record in records:
        if not record:
            continue
        spec, filename = record.split(b"\t", 1)
        mode, kind, object_id = spec.split()
        name = filename.decode()
        if kind == b"commit":
            children.append((path / name, object_id.decode()))
        else:
            tracked.add(name)
    # Untracked/ignored .sol files can affect Foundry import resolution. Check only
    # dependency source directories, excluding build artifacts and child modules.
    for folder in ("src", "test", "contracts"):
        base = path / folder
        if base.exists():
            for source in base.rglob("*.sol"):
                if str(source.relative_to(path)) not in tracked:
                    raise RuntimeError(f"{source.relative_to(ROOT)}: unexpected Solidity source")
    for child, expected in children:
        check_checkout(child, expected)


def main():
    lock = json.loads((ROOT / "dependencies.lock.json").read_text())
    for dependency in lock["dependencies"]:
        path = dependency["path"]
        entry = git(ROOT, "ls-files", "--stage", "--", path).decode().strip()
        if not entry or entry.split()[:3] != ["160000", dependency["commit"], "0"]:
            raise RuntimeError(f"{path}: Git index and dependency lock disagree")
        url = git(ROOT, "config", "--file", ".gitmodules", "--get",
                  f"submodule.{path}.url").decode().strip()
        if url != dependency["url"]:
            raise RuntimeError(f"{path}: upstream URL and dependency lock disagree")
        check_checkout(ROOT / dependency["path"], dependency["commit"])
    print("Dependency revisions and tracked files verified, including recursive submodules.")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error)) from error
