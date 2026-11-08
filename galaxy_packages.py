"""Prepare reusable Galaxy wheels for the action's non-default branch override."""

import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

PACKAGES = ("galaxy_util", "galaxy_tool_util_models", "galaxy_tool_util")
PACKAGE_DIRS = ("util", "tool_util_models", "tool_util")


def resolve_commit(repository, reference):
    if re.fullmatch(r"[0-9a-fA-F]{40}", reference):
        return reference.lower()
    refs = [f"refs/heads/{reference}", f"refs/tags/{reference}^{{}}", f"refs/tags/{reference}"]
    result = subprocess.run(
        ["git", "ls-remote", repository, *refs], check=True, capture_output=True, text=True
    )
    commits = dict(line.split()[::-1] for line in result.stdout.splitlines())
    for ref in refs:
        if ref in commits:
            return commits[ref]
    raise ValueError(f"Cannot resolve Galaxy reference {reference!r} in {repository}")


def cache_key(repository, commit):
    identity = [repository, commit, platform.system(), platform.machine(), sys.version]
    return hashlib.sha256(json.dumps(identity).encode()).hexdigest()


def cached_wheels(directory, repository, commit):
    try:
        manifest = json.loads((directory / "manifest.json").read_text())
        if manifest["repository"] != repository or manifest["commit"] != commit:
            return None
        names = manifest["wheels"]
        if len(names) != len(PACKAGES):
            return None
        for package, name in zip(PACKAGES, names):
            if Path(name).name != name or not name.startswith(package + "-") or not name.endswith(".whl"):
                return None
        wheels = [directory / name for name in names]
        return wheels if all(path.is_file() for path in wheels) else None
    except (OSError, ValueError, KeyError, TypeError):
        return None


def prepare_wheels(repository, commit, directory):
    wheels = cached_wheels(directory, repository, commit)
    if wheels:
        print(f"Using cached Galaxy wheels for {commit}", flush=True)
        return wheels

    print(f"Building Galaxy wheels from one checkout of {repository} at {commit}", flush=True)
    directory.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=directory.parent) as temporary:
        source = Path(temporary) / "source"
        output = Path(temporary) / "wheels"
        subprocess.run(["git", "init", "--quiet", str(source)], check=True)
        subprocess.run(["git", "-C", str(source), "fetch", "--depth=1", repository, commit], check=True)
        subprocess.run(["git", "-C", str(source), "checkout", "--quiet", "--detach", "FETCH_HEAD"], check=True)
        subprocess.run(
            [sys.executable, "-m", "pip", "wheel", "--no-deps", "--wheel-dir", str(output),
             *(str(source / "packages" / name) for name in PACKAGE_DIRS)],
            check=True,
        )
        names = []
        for package in PACKAGES:
            matches = list(output.glob(f"{package}-*.whl"))
            if len(matches) != 1:
                raise ValueError(f"Expected one wheel for {package}, found {len(matches)}")
            names.append(matches[0].name)
        (output / "manifest.json").write_text(json.dumps({
            "repository": repository, "commit": commit, "wheels": names,
        }))
        # A partial or incompatible restored entry must not be mistaken for a hit.
        if directory.exists():
            shutil.rmtree(directory)
        output.rename(directory)
    return [directory / name for name in names]


def install_packages(repository, commit, directory):
    wheels = [str(path) for path in prepare_wheels(repository, commit, directory)]
    # Branches can share a package version: replace these three packages even
    # when pip considers their versions equal, without reinstalling every dependency.
    subprocess.run(
        [sys.executable, "-m", "pip", "install", "--force-reinstall", "--no-deps", *wheels], check=True
    )
    subprocess.run([sys.executable, "-m", "pip", "install", *wheels], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("resolve", "install"))
    args = parser.parse_args()
    repository = f"https://github.com/{os.environ['GALAXY_FORK']}/galaxy.git"
    if args.command == "resolve":
        commit = resolve_commit(repository, os.environ["GALAXY_BRANCH"])
        key = cache_key(repository, commit)
        directory = Path(os.environ["RUNNER_TEMP"]) / "galaxy-package-wheels" / key
        with open(os.environ["GITHUB_OUTPUT"], "a") as output:
            output.write(f"commit={commit}\ncache-key={key}\nwheel-dir={directory}\n")
    else:
        install_packages(repository, os.environ["GALAXY_PACKAGE_COMMIT"], Path(os.environ["GALAXY_WHEEL_DIR"]))


if __name__ == "__main__":
    main()
