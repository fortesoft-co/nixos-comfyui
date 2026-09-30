"""Declarative workflow mirror for ComfyUI.

Runs from the comfyui-workflows-install oneshot (service user, before
comfyui.service). cfg.comfyui.workflows entries install into a pass-owned,
read-only mirror directory (<workflowsDir>/nix-managed/<subpath>); the pass
never touches anything outside that directory — files deployed directly
under the workflows root belong to the user.

Mirror law:
  each manifest entry carries the repo content as a nix store path.
  missing     -> copied in (0444)
  identical   -> left alone
  different   -> rewritten (0444): the mirror always tracks the repo
  unclaimed   -> removed: anything under the mirror root that the current
                 manifest does not claim is the pass's own leftover, auto-
                 removed (loud log). Consumer git history is the recovery
                 path for dropped entries.

Read-only enforcement lives in the DIRECTORY modes, not the file modes:
ComfyUI's userdata API saves via tempfile.mkstemp(dir) + os.replace, which
needs write permission on the directory only, so a 0444 file alone cannot
protect itself. Between passes every directory under the mirror root is
0555 and every file 0444 — save/move/delete attempts against the mirror
fail loudly at the API, while listing and opening (r-x) keep working.

No network I/O; sources are immutable nix store paths.
"""
import argparse
import json
import os
import shutil
import sys
from pathlib import Path

CODE_W = 8
FILE_MODE = 0o444
DIR_SEAL = 0o555
DIR_OPEN = 0o755


def log(code: str, rel: str, msg: str) -> None:
    print(f"{code:<{CODE_W}} {rel:<44} {msg}", flush=True)


def fail(eid: str, msg: str) -> None:
    print(f"FAIL      {eid:<44} {msg}", file=sys.stderr, flush=True)


def read_bytes(path: Path) -> bytes:
    with open(path, "rb") as f:
        return f.read()


def widen(root: Path) -> None:
    for p in [root] + sorted(root.rglob("*")):
        if p.is_dir() and not p.is_symlink():
            p.chmod(DIR_OPEN)


def seal(root: Path) -> None:
    for p in [root] + sorted(root.rglob("*"), reverse=True):
        if p.is_dir() and not p.is_symlink():
            p.chmod(DIR_SEAL)


def run(manifest_path: str, data_dir: Path, managed_rel: str) -> int:
    rel_path = Path(managed_rel)
    managed = data_dir / rel_path
    if rel_path.is_absolute() or ".." in rel_path.parts:
        fail("(args)", "--managed must be a dataDir-relative path")
        return 1
    # The managed root nests inside a shared read-only directory (sibling
    # owners install their own namespaces there). Widening the parent and
    # re-sealing it at the end keeps that shared structure coherent across
    # every pass that touches it.
    shared = managed.parent
    if managed.exists() and not managed.is_dir():
        fail("(mirror)", f"{managed} exists but is not a directory")
        return 1
    widen(shared)
    managed.mkdir(parents=True, exist_ok=True)

    prefix = managed_rel + "/"

    try:
        with open(manifest_path, "r") as f:
            entries = json.load(f)
        if isinstance(entries, dict):
            entries = [{"id": k, **v} for k, v in entries.items()]
    except (OSError, ValueError) as e:
        fail("(manifest)", f"unreadable: {e}")
        return 1

    claimed = set()
    written = current = refreshed = healed = removed = pruned = failures = 0

    for entry in entries:
        eid = dest = src = None
        try:
            eid = entry["id"]
            dest = entry["dest"]
            src = Path(entry["src"])
        except (KeyError, TypeError):
            fail(eid or "(entry)", f"malformed manifest entry: {entry!r}")
            failures += 1
            continue

        if not dest.startswith(prefix):
            fail(eid, f"dest {dest} is outside the mirror root {managed_rel}")
            failures += 1
            continue
        rel = dest[len(prefix):]
        dst = managed / rel

        if not src.is_file():
            fail(eid, f"manifest source missing: {src}")
            failures += 1
            continue
        body = read_bytes(src)

        if dst.exists() and not dst.is_file():
            fail(eid, f"dest exists but is not a regular file: {dst}")
            failures += 1
            continue

        if not dst.exists():
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(src, dst)
            dst.chmod(FILE_MODE)
            log("MIRROR", eid, "installed managed workflow")
            written += 1
        elif read_bytes(dst) == body:
            if (dst.stat().st_mode & 0o777) == FILE_MODE:
                log("OK", eid, "mirror current")
                current += 1
            else:
                dst.chmod(FILE_MODE)
                log("PERM", eid, "content ok — mode restored 0444")
                healed += 1
        else:
            dst.unlink()
            shutil.copyfile(src, dst)
            dst.chmod(FILE_MODE)
            log("UPDATE", eid, "repo content changed — mirror rewritten")
            refreshed += 1
        claimed.add(rel)

    for path in sorted(x for x in managed.rglob("*") if x.is_file() and not x.is_symlink()):
        rel = path.relative_to(managed).as_posix()
        if rel not in claimed:
            path.unlink()
            log("REMOVED", rel, "unclaimed leftover (content stays in consumer git history)")
            removed += 1

    for path in sorted(managed.rglob("*")):
        if path.is_symlink() or (path.exists() and not path.is_file() and not path.is_dir()):
            log(
                "ORPHAN",
                path.relative_to(managed).as_posix(),
                "non-regular mirror entry — listed, never removed",
            )

    for dirpath, _dirnames, _filenames in os.walk(managed, topdown=False):
        candidate = Path(dirpath)
        if candidate != managed and not any(candidate.iterdir()):
            candidate.rmdir()
            log("PRUNE", candidate.relative_to(managed).as_posix(), "empty mirror directory")
            pruned += 1

    seal(shared)
    print(
        f"mirror pass: {written} written, {current} current, {refreshed} refreshed, "
        f"{healed} perm-healed, {removed} removed, {pruned} pruned, {failures} failed",
        flush=True,
    )
    return 1 if failures else 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Mirror declarative ComfyUI workflows into a read-only directory"
    )
    parser.add_argument("--manifest", required=True, help="path to the workflow manifest JSON")
    parser.add_argument("--dataDir", required=True, type=Path, help="ComfyUI data directory")
    parser.add_argument(
        "--managed",
        required=True,
        help="dataDir-relative mirror root (e.g. user/default/workflows/nix-managed)",
    )
    args = parser.parse_args()
    return run(args.manifest, args.dataDir, args.managed)


if __name__ == "__main__":
    sys.exit(main())
