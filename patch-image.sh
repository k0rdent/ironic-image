#!/usr/bin/bash
set -euxo pipefail

# Apply patches from patches/<project>/*.patch before pip installs from
# ironic-packages-list-final. For each project with patch files, the matching
# requirement line is replaced with file:///sources/<repo> (not git+file: pip
# would clone from .git and omit uncommitted git-apply changes).

PATCHES_ROOT="/tmp/patches"
IRONIC_PKG_LIST_FINAL="/tmp/ironic-packages-list-final"

[[ -d "${PATCHES_ROOT}" ]] || exit 0

export PATCHES_ROOT IRONIC_PKG_LIST_FINAL
export GIT_HOST="${GIT_HOST:-https://opendev.org}"

python3.12 <<'PY'
import os
import re
import shutil
import subprocess
import sys

PATCHES_ROOT = os.environ["PATCHES_ROOT"]
FINAL = os.environ["IRONIC_PKG_LIST_FINAL"]
GIT_BASE = os.environ.get("GIT_HOST", "https://opendev.org").rstrip("/")
SOURCES = "/sources"

def git(*args: str, cwd: str | None = None) -> None:
    subprocess.run(["git", *args], cwd=cwd, check=True)


def project_for_rel(rel: str) -> str:
    return rel if "/" in rel else f"openstack/{rel}"


def line_matches_project(line: str, project: str, short: str) -> bool:
    # Patched installs use a plain file:// URL so pip uses the working tree.
    # git+file:// would make pip git-clone the repo, which only copies commits
    # and drops uncommitted changes from git apply.
    if f"file:///sources/{short}" in line:
        return True
    if f"git+file:///sources/{short}" in line:
        return True
    boundary = re.compile(re.escape("/" + project) + r"(?=@|[#\"'\s]|$)")
    return boundary.search(line) is not None


def parse_pkg_url(line: str, short: str) -> tuple[str, str]:
    if " @ " in line:
        pkg, url_spec = line.split(" @ ", 1)
        return pkg.strip(), url_spec.strip()
    return short, line.strip()


def extract_ref(url_spec: str, project: str) -> str | None:
    mark = "/" + project
    if mark not in url_spec:
        return None
    i = url_spec.index(mark) + len(mark)
    if i < len(url_spec) and url_spec[i] == "@":
        return url_spec[i + 1 :].split("#")[0].strip()
    return None


# Collect patch files grouped by project directory (relative to PATCHES_ROOT).
by_rel: dict[str, list[str]] = {}
for root, _dirs, files in os.walk(PATCHES_ROOT):
    for name in sorted(files):
        if not name.endswith((".patch", ".diff")):
            continue
        path = os.path.join(root, name)
        rel = os.path.relpath(os.path.dirname(path), PATCHES_ROOT)
        if rel == ".":
            print(
                f"WARNING: ignore patch at root of {PATCHES_ROOT}: {path}",
                file=sys.stderr,
            )
            continue
        by_rel.setdefault(rel, []).append(path)

for rel in by_rel:
    by_rel[rel] = sorted(by_rel[rel])

if not by_rel:
    sys.exit(0)

with open(FINAL) as f:
    lines = f.read().splitlines()

for rel in sorted(by_rel.keys()):
    project = project_for_rel(rel)
    short = project.split("/")[-1]
    match_idx = None
    for i, line in enumerate(lines):
        if line_matches_project(line, project, short):
            match_idx = i
            break
    if match_idx is None:
        print(
            f"WARNING: no requirement line for {project}; skip patches under {rel!r}",
            file=sys.stderr,
        )
        continue

    line = lines[match_idx]
    pkg, url_spec = parse_pkg_url(line, short)
    ref = extract_ref(url_spec, project)

    dest = os.path.join(SOURCES, short)
    shutil.rmtree(dest, ignore_errors=True)
    os.makedirs(SOURCES, exist_ok=True)
    git("clone", f"{GIT_BASE}/{project}.git", dest)
    if ref:
        git("fetch", "origin", ref, cwd=dest)
        git("checkout", "FETCH_HEAD", cwd=dest)

    for patch_path in by_rel[rel]:
        print(
            f"DEBUG: Applying patch {patch_path}",
            file=sys.stderr,
        )
        git("apply", patch_path, cwd=dest)

    lines[match_idx] = f"{pkg} @ file:///sources/{short}"

with open(FINAL, "w") as f:
    f.write("\n".join(lines) + "\n")
PY
