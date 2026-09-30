"""download_runtime — systemd entry points for the pin-store design.
One binary, three subcommands, three units:

    <bin> ensure  --manifest pins.json ...   (boot pass; comfyui user)
        stat/readlink per pin, no content reads at steady state: relink
        semantic paths whose store blob already exists (recreating the
        link when only the blob made it, fetching when only the link
        made it); fetch missing pins into <work>/staging (resumable curl
        with the entry's token), sha-gate them, and record them as rows
        in <work>/promote.json for the seal
        - reconcile foreign real files at semantic paths: digest match ->
          promote(kind=adopt) so the seal moves/link; mismatch -> fetch a
          verified replacement and park the impostor in <work>/quarantine
          (swap-after-verified-download: old bytes freed only after the
          verified replacement lands)
        - unzipInto bundle entries and dest entries outside models/ keep
          today's real-file handling: fetch straight to the dest
          (sha-gated), extract when unzipInto, verify against the
          checksum manifest each pass
    <bin> seal    --manifest ...   (root oneshot)
        consumes promote.json: re-measures every row's bytes, places them
        into <store>/<name>--<digest><ext> (0444, root:root), writes the
        .pin.json provenance freebie + store README, creates the
        semantic symlink. Root performs placement + ownership only — no
        network I/O.
    <bin> audit   --manifest pins.json ...    (comfyui, quarterly timer)
        everything ensure does, plus a full sweep of the store: every
        blob is re-measured and must hash to its embedded digest; blobs
        without a pin are listed as orphans (never deleted); files that
        do not match the blob naming are listed as unrecognized.

Store law (same as the migration tool):
    blob    = <store>/<stem>--<full-sha256><ext>   name = measured bytes
    sidecar = <blob>.pin.json                     provenance freebie
    link    = absolute symlink at models/<type>/<arch>/<name>

Under systemd the units set PATH through the `path` option (pinned nix
store dirs for curl/openssl/sha256sum, provided by the module), so the
ambient host PATH is never consulted; bare manual runs resolve from the
operator's PATH.
"""

import argparse
import concurrent.futures
import dataclasses
import datetime
import grp
import json
import os
import pwd
import re
import shutil
import subprocess
import sys
import zipfile

VERSION = "download_runtime 1.2"

CURL_CANDIDATES = ["curl"]
OPENSSL_CANDIDATES = ["openssl"]
EMPTY_SHA = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
BLOB_RE = re.compile(r"^(?P<stem>.+)--(?P<dig>[0-9a-f]{64})(?P<ext>\.[^.]+)?$")

STORE_README = """# ComfyUI model store

This directory holds the canonical, one-copy-per-content records of the
model files managed declaratively by Nix (the `cfg.comfyui.downloads`
pin set). Entries in models/** are *symlinks* into this directory —
ComfyUI, LoRA Manager and Krita read through them like normal files.

- Names look like `<original-name>--<sha256-hex>.<original-ext>`. The
  hash in the name IS this file's content: placement and every
  maintenance pass re-measure the bytes and require them to match the
  name. If a tool reports a store file whose name does not match its
  content, something wrote here outside the pipeline — treat it as
  suspect and check the audit journal.
- These files are root-owned and read-only on purpose. Do not edit,
  rename, bulk-move or delete them by hand: a deleted blob is
  re-downloadable, and the declarative pin set in the consumer's NixOS
  host configuration is what re-creates the links.
- A missing/broken model entry usually means the *symlink* (in
  models/**) is dangling or the blob was moved — the boot pass relinks
  automatically; manual fix = point the symlink back at the right file
  here.
- `*.pin.json` files are the provenance cards (which civitai/HF card,
  when placed); they are convenience, not load-bearing.
- Seeing two blobs with identical bytes but different names (same
  model, different pin names) is expected.
"""


def warn(msg):
    print(f"warn: {msg}", file=sys.stderr)


def note(msg):
    print(msg)


def is_root():
    return os.geteuid() == 0


def find_tool(candidates, name, optional=False):
    for c in candidates:
        if os.sep in c:
            if os.path.exists(c):
                return c
        else:
            p = shutil.which(c)
            if p:
                return p
    if not optional:
        sys.exit(f"{name} not found — refusing to continue ({name} is required)")
    return None


def sha256_of(tool, path):
    try:
        r = subprocess.run([tool, "dgst", "-sha256", "-r", path], capture_output=True, text=True)
    except OSError as e:
        warn(f"hash spawn failed for {path}: {e}")
        return None
    if r.returncode != 0:
        warn(f"hash failed for {path}: {r.stderr.strip()[:200]}")
        return None
    return r.stdout.split(" ")[0]


@dataclasses.dataclass
class Pin:
    """One manifest row — the nix definition, resolved by downloads.nix."""

    raw: dict

    @property
    def id(self):
        return self.raw["id"]

    @property
    def sha256(self):
        return (self.raw.get("sha256") or "").strip().lower() or None

    @property
    def dest_rel(self):
        return self.raw.get("dest") or None

    @property
    def store_blob_name(self):
        if not self.sha256:
            return None
        basename = (self.dest_rel or self.id).rsplit("/", 1)[-1]
        stem, ext = os.path.splitext(basename)
        return f"{stem}--{self.sha256}{ext}"

    @property
    def legacy(self):
        """True for entries that keep real-file handling (workflows/dest)."""
        return bool(self.raw.get("legacy"))

    @property
    def token(self):
        tf = self.raw.get("tokenFile") or None
        if not tf or not os.path.isfile(tf):
            return None
        try:
            with open(tf, "rb") as f:
                tok = f.read().strip().decode("utf-8", "replace").strip()
            return tok or None
        except OSError as e:
            warn(f"token unreadable for {self.id}: {e} — fetching without")
            return None


def load_pins(manifest, only):
    with open(manifest) as f:
        rows = json.load(f)
    pins = [Pin(r) for r in rows]
    if only:
        pins = [p for p in pins if p.id in only]
    return pins


def hashed_parallel(tool, paths, jobs):
    out = {}
    if not paths:
        return out
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, jobs)) as pool:
        futs = {pool.submit(sha256_of, tool, p): p for p in paths}
        for fut in concurrent.futures.as_completed(futs):
            out[futs[fut]] = fut.result()
    return out


def scan_store(store_dir):
    pairs, unrecognized = [], []
    if not os.path.isdir(store_dir):
        return pairs, unrecognized
    for name in sorted(os.listdir(store_dir)):
        if name.endswith(".pin.json") or name == "README.md":
            continue
        path = os.path.join(store_dir, name)
        if not os.path.isfile(path):
            continue
        m = BLOB_RE.match(name)
        if m:
            pairs.append((path, m.group("dig")))
        else:
            unrecognized.append(path)
    return pairs, unrecognized


def write_store_readme(store_dir):
    path = os.path.join(store_dir, "README.md")
    if os.path.exists(path):
        return False
    tmp = path + f".{os.getpid()}.tmp"
    with open(tmp, "w") as f:
        f.write(STORE_README)
    os.replace(tmp, path)
    note(f"README  {path}")
    return True


def write_sidecar(blob_path, provenance, pin_id):
    side = blob_path + ".pin.json"
    if os.path.exists(side):
        return False
    doc = dict(provenance or {})
    doc.setdefault("pin", pin_id)
    doc["sha256"] = row_digest_of(blob_path)
    doc["size"] = os.path.getsize(blob_path)
    doc["placed_at"] = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
    doc["placed_by"] = VERSION
    tmp = side + f".{os.getpid()}.tmp"
    with open(tmp, "w") as f:
        json.dump(doc, f, indent=2, sort_keys=True)
        f.write("\n")
    os.replace(tmp, side)
    try:
        os.chmod(side, 0o444)
    except OSError as e:
        warn(f"chmod failed on {side}: {e}")
    note(f"SIDECAR {pin_id}: {side}")
    return True


def row_digest_of(blob_path):
    m = BLOB_RE.match(os.path.basename(blob_path))
    return m.group("dig") if m else ""


def make_link(pin_id, link_abs, blob_path, uid=None, gid=None):
    parent = os.path.dirname(link_abs)
    makedirs_managed(parent, uid, gid)
    tmp = os.path.join(parent, f".pinlink.{os.getpid()}.{re.sub('[^A-Za-z0-9_.]', '_', pin_id)}.tmp")
    if os.path.lexists(tmp):
        os.remove(tmp)
    os.symlink(blob_path, tmp)
    if os.path.islink(link_abs) and os.readlink(link_abs) == blob_path:
        os.remove(tmp)
        return
    os.replace(tmp, link_abs)
    note(f"LINKED  {pin_id}: {link_abs} -> {blob_path}")


def unzip_bundle(openssl, archive, into_dir, archive_sha):
    """Extract <archive> into <into_dir>, manifest-verify the tree each
    run, re-extract on drift. The archive itself is already sha-gated."""
    os.makedirs(into_dir, exist_ok=True)
    apple = os.path.join(into_dir, "__MACOSX")
    if os.path.isdir(apple):
        shutil.rmtree(apple, ignore_errors=True)
    stamp = os.path.join(into_dir, ".unzipped")
    stamped = False
    if os.path.isfile(stamp):
        try:
            stamped = open(stamp).read().strip() == archive_sha
        except OSError:
            stamped = False
    if stamped:
        man = os.path.join(into_dir, ".unzipped.sha256")
        if os.path.isfile(man) and os.path.getsize(man) > 0:
            r = subprocess.run(["sha256sum", "--quiet", "-c", ".unzipped.sha256"],
                               cwd=into_dir, capture_output=True)
            if r.returncode == 0:
                return
        note(f"  extracted tree drifted under {into_dir} — re-extracting")

    with zipfile.ZipFile(archive) as z:
        z.extractall(into_dir)
    if os.path.isdir(apple):
        shutil.rmtree(apple, ignore_errors=True)
    with open(stamp, "w") as f:
        f.write(archive_sha + "\n")
    lines = []
    with zipfile.ZipFile(archive) as z:
        names = sorted(n for n in z.namelist() if not n.endswith("/") and not n.startswith("__MACOSX/"))
    for n in names:
        ap = os.path.join(into_dir, n)
        r = subprocess.run(["sha256sum", ap], capture_output=True, text=True)
        if r.returncode != 0:
            raise RuntimeError(f"manifest hash failed for {ap}")
        lines.append(r.stdout.rstrip("\n").replace(ap, n, 1))
    with open(os.path.join(into_dir, ".unzipped.sha256"), "w") as f:
        f.write("\n".join(lines) + ("\n" if lines else ""))


def fetch_part(curl_tool, openssl, pin, staging, urls=None):
    """Resumable staged download for store-bound pins; verifies sha.
    Returns the staged path on success, else None (debris removed itself
    on mismatch; failures leave the .part for a later resume)."""
    part = os.path.join(staging, f"{pin.store_blob_name}.part")
    if urls is None:
        urls = pin.raw.get("urls") or []
    for url in urls:
        note(f"  fetching: {url}")
        cmd = [curl_tool, "-L", "--fail", "--retry", "5", "--connect-timeout", "30", "-C", "-"]
        tok = pin.token
        if tok:
            cmd += ["--header", f"Authorization: Bearer {tok}"]
        cmd += ["-o", part, url]
        r = subprocess.run(cmd, check=False)
        if r.returncode != 0:
            warn(f"  fetch failed ({pin.id}): curl exit {r.returncode}")
            continue
        digest = sha256_of(openssl, part)
        if digest is None:
            continue
        if digest != pin.sha256:
            warn(f"  sha256 mismatch for {pin.id} (have {digest}, want {pin.sha256}) — removing debris")
            try:
                os.remove(part)
            except OSError:
                pass
            continue
        return part
    return None


def makedirs_managed(path, uid, gid):
    """Create path, giving only the newly created segments ownership/mode.
    Link parent dirs land 0775 <user>:<group> so foreign writers (LoRA
    Manager organize, node packs) keep arranging them; existing
    directories are left untouched."""
    missing = []
    cur = path
    while not os.path.isdir(cur):
        missing.append(cur)
        nxt = os.path.dirname(cur)
        if nxt == cur:
            break
        cur = nxt
    os.makedirs(path, exist_ok=True)
    for d in missing:
        try:
            os.chmod(d, 0o775 if uid is not None else 0o755)
        except OSError as e:
            warn(f"chmod failed on {d}: {e}")
        if uid is not None and os.geteuid() == 0:
            try:
                os.chown(d, uid, gid)
            except (PermissionError, KeyError, OSError) as e:
                warn(f"chown failed on {d}: {e}")


def cmd_ensure(args):
    """Boot pass as the service user."""
    data_dir = os.path.abspath(args.dataDir)
    store_dir = os.path.join(data_dir, args.store)
    work = os.path.join(data_dir, args.work)
    staging = os.path.join(work, "staging")
    quarantine = os.path.join(work, "quarantine")
    promote_path = os.path.join(work, "promote.json")
    curl_tool = find_tool(CURL_CANDIDATES, "curl")
    openssl = find_tool(OPENSSL_CANDIDATES, "openssl")

    pins = load_pins(args.manifest, args.only)
    os.makedirs(staging, exist_ok=True)
    os.makedirs(quarantine, exist_ok=True)

    promote = []
    failed = 0

    for p in pins:
        dest_rel = p.dest_rel
        if not dest_rel:
            warn(f"fail {p.id}: manifest entry without dest")
            failed += 1
            continue
        dest_abs = os.path.join(data_dir, dest_rel)

        if p.legacy:
            # ---- real-file handling (workflows + unzipInto bundles) ----
            if not p.sha256 or len(p.sha256) != 64 or p.sha256 == EMPTY_SHA:
                warn(f"fail {p.id}: missing/invalid sha256")
                failed += 1
                continue
            if os.path.isfile(dest_abs):
                note(f"have {p.id}: {dest_abs}")
            elif os.path.exists(dest_abs):
                warn(f"impostor {p.id}: {dest_abs} — untouched")
                failed += 1
            else:
                if not p.raw.get("urls"):
                    warn(f"fail {p.id}: dest missing and no url")
                    failed += 1
                    continue
                if not fetch_part(curl_tool, openssl, p, staging, p.raw.get("urls")):
                    warn(f"FETCH FAILED {p.id}")
                    failed += 1
                    continue
                makedirs_managed(os.path.dirname(dest_abs), None, None)
                os.replace(os.path.join(staging, f"{p.store_blob_name}.part"), dest_abs)
                note(f"FETCHED {p.id}: {dest_abs}")
            if p.raw.get("unzipInto"):
                into = os.path.join(data_dir, p.raw["unzipInto"])
                try:
                    unzip_bundle(openssl, dest_abs, into, p.sha256)
                    note(f"ok {p.id}: bundle verified/extracted")
                except RuntimeError as e:
                    warn(f"fail {p.id}: {e}")
                    failed += 1
            continue

        # ---- content-addressed (models/**) -----------------------------
        if not p.sha256 or len(p.sha256) != 64 or p.sha256 == EMPTY_SHA:
            warn(f"fail {p.id}: missing/invalid sha256")
            failed += 1
            continue
        blob_path = os.path.join(store_dir, p.store_blob_name)
        matches = [path_ for path_, dig in scan_store(store_dir)[0] if dig == p.sha256]

        if os.path.islink(dest_abs):
            target = os.readlink(dest_abs)
            if not os.path.isabs(target):
                target = os.path.join(os.path.dirname(dest_abs), target)
            if matches and target == matches[0] and os.path.isfile(matches[0]):
                note(f"ok {p.id}: link correct")
                continue
            if matches:
                if args.enforce:
                    make_link(p.id, dest_abs, matches[0])
                else:
                    note(f"ok (unenforced) {p.id}: wrong link target left alone")
                continue
            # dangling link with no blob anywhere — fetch so the next
            # seal re-points it (the pointer itself is left in place).
            fetch_reason = f"dangling link -> {target}"
        elif os.path.isfile(dest_abs):
            if not args.enforce:
                note(f"have (unenforced) {p.id}: {dest_abs}")
                continue
            dig = sha256_of(openssl, dest_abs)
            if dig is None:
                failed += 1
                continue
            if dig == p.sha256:
                if matches:
                    # bytes verified identical to an existing blob — relink
                    make_link(p.id, dest_abs, matches[0])
                    continue
                note(f"promote(adopt) {p.id}: {dest_abs} -> {blob_path}")
                promote.append({"pin": p.id, "kind": "adopt",
                                "source": dest_abs, "digest": dig,
                                "link": dest_abs, "blob": blob_path,
                                "provenance": p.raw.get("provenance")})
                continue
            # bytes diverge from the pin — shared fetch tail below
            fetch_reason = f"impostor (hashes {dig})"
        elif os.path.exists(dest_abs):
            if args.enforce:
                warn(f"impostor {p.id}: non-regular object at {dest_abs} — untouched")
                failed += 1
            else:
                note(f"ok (unenforced) {p.id}: non-regular object at {dest_abs}")
            continue
        elif matches:
            # dest gone while its content-addressed blob is intact —
            # recreate the link instead of re-downloading (foreign-writer
            # adoption).
            if args.enforce:
                make_link(p.id, dest_abs, matches[0])
            else:
                note(f"ok (unenforced) {p.id}: dest missing, blob present — not relinked")
            continue
        else:
            fetch_reason = "dest missing"

        # Shared fetch tail. An impostor with its blob still intact needs
        # no download: park it and relink. Otherwise the swap only frees
        # the old bytes after a verified replacement reached staging.
        if matches and os.path.exists(dest_abs) and not os.path.islink(dest_abs) and args.enforce:
            ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
            drift = os.path.join(quarantine, f"{p.id}-{ts}.drift")
            os.replace(dest_abs, drift)
            note(f"quarantined impostor {p.id}: {drift}")
            make_link(p.id, dest_abs, matches[0])
            continue
        if not p.raw.get("urls"):
            warn(f"fail {p.id}: dest missing and no url ({fetch_reason})")
            failed += 1
            continue
        staged = fetch_part(curl_tool, openssl, p, staging)
        if staged is None:
            warn(f"FETCH FAILED {p.id} ({fetch_reason})")
            failed += 1
            continue
        if os.path.exists(dest_abs) and not os.path.islink(dest_abs):
            ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
            drift = os.path.join(quarantine, f"{p.id}-{ts}.drift")
            os.replace(dest_abs, drift)
            note(f"quarantined impostor {p.id}: {drift}")
        promote.append({"pin": p.id, "kind": "fetch", "source": staged,
                        "digest": p.sha256, "link": dest_abs,
                        "blob": blob_path,
                        "provenance": p.raw.get("provenance")})
        note(f"promote(fetch) {p.id}")
        # /models branch
    # /pins

    tmp = promote_path + f".{os.getpid()}.tmp"
    with open(tmp, "w") as f:
        json.dump(promote, f, indent=1, sort_keys=True)
    os.replace(tmp, promote_path)

    if failed:
        warn(f"ensure: {failed} pin(s) failed")
    return 1 if failed else 0


def cmd_seal(args):
    """Root placement pass: re-measure promoted bytes, place, own, link."""
    data_dir = os.path.abspath(args.dataDir)
    store_dir = os.path.join(data_dir, args.store)
    work = os.path.join(data_dir, args.work)
    promote_file = os.path.join(work, "promote.json")
    quarantine = os.path.join(work, "quarantine")
    openssl = find_tool(OPENSSL_CANDIDATES, "openssl")

    # Link dirs under models/** are chowned to the service's user:group
    # (0775) so foreign writers keep arranging them; blobs stay root-owned
    # inside the store. The flag is best-effort: unknown user/group just
    # leaves dirs as-created.
    link_uid = link_gid = None
    if args.link_owner and is_root():
        try:
            owner_name, group_name = args.link_owner.split(":", 1)
            link_uid = pwd.getpwnam(owner_name).pw_uid
            link_gid = grp.getgrnam(group_name).gr_gid
        except (KeyError, ValueError) as e:
            warn(f"link-owner {args.link_owner} unknown ({e}) — leaving link dirs as-created")
    if not os.path.isfile(promote_file):
        note("seal: no promote.json — nothing to do")
        os.makedirs(store_dir, exist_ok=True)
        write_store_readme(store_dir)
        return 0
    with open(promote_file) as f:
        rows = json.load(f)
    failed = 0
    os.makedirs(store_dir, exist_ok=True)
    write_store_readme(store_dir)
    for row in rows:
        pin_id = row["pin"]
        src = row["source"]
        blob = row["blob"]
        link = row["link"]
        dig = sha256_of(openssl, src)
        if dig is None:
            warn(f"seal failed {pin_id}: hash error on {src}")
            failed += 1
            continue
        if dig != row["digest"]:
            ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
            park = os.path.join(quarantine, f"{pin_id}-{ts}.failed")
            try:
                os.replace(src, park)
                warn(f"seal failed {pin_id}: hashes {dig}, pin {row['digest']} — parked {park}")
            except OSError as e:
                warn(f"seal failed {pin_id}: hash mismatch and quarantine failed: {e}")
            failed += 1
            continue
        if os.path.isfile(blob):
            # something already sits at the intended name — verify it.
            # verified match → relink and free the verified duplicate;
            # mismatch → park the occupant (root), place our verified bytes.
            existing_dig = sha256_of(openssl, blob)
            if existing_dig == row["digest"]:
                if src != blob:
                    try:
                        os.remove(src)  # verified duplicate bytes — discardable
                    except OSError as e:
                        warn(f"cleanup failed for {src}: {e}")
                note(f"DEDUP {pin_id}: reusing {blob}")
            else:
                ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
                park = os.path.join(quarantine, f"{pin_id}-store-{ts}.drift")
                try:
                    os.replace(blob, park)
                    warn(f"store impostor at {blob} (hashes {existing_dig}) — parked {park}")
                    os.replace(src, blob)
                    write_sidecar(blob, row.get("provenance"), pin_id)
                    note(f"PLACED {pin_id}: {blob}")
                except OSError as e:
                    warn(f"seal failed {pin_id}: could not replace store impostor {blob}: {e}")
                    failed += 1
                    continue
        else:
            m = BLOB_RE.match(os.path.basename(blob))
            digest = m.group("dig") if m else None
            if digest != row["digest"]:
                warn(f"seal failed {pin_id}: blob name does not encode the verified digest ({blob})")
                failed += 1
                continue
            os.replace(src, blob)
            try:
                os.chmod(blob, 0o444)
                if os.geteuid() == 0:
                    os.chown(blob, 0, 0)
            except OSError as e:
                warn(f"perm fix failed on {blob}: {e}")
            write_sidecar(blob, row.get("provenance"), pin_id)
            note(f"PLACED {pin_id}: {blob}")
        make_link(pin_id, link, blob, link_uid, link_gid)
    try:
        os.remove(promote_file)
    except OSError as e:
        warn(f"could not clear promote.json: {e}")
    if failed:
        warn(f"seal: {failed} row(s) failed")
    return 1 if failed else 0


def cmd_audit(args):
    """ensure + full store sweep + orphans. Never deletes."""
    rc = cmd_ensure(args)
    data_dir = os.path.abspath(args.dataDir)
    store_dir = os.path.join(data_dir, args.store)
    openssl = find_tool(OPENSSL_CANDIDATES, "openssl")
    pins = load_pins(args.manifest, args.only)
    pinned = {p.sha256 for p in pins if p.sha256}
    pairs, unparsed = scan_store(store_dir)
    paths = [path_ for path_, _ in pairs]
    digests = hashed_parallel(openssl, paths, args.jobs)
    sweep_failed = 0
    for path_, dig in pairs:
        measured = digests.get(path_)
        if measured != dig:
            warn(f"audit FAILED: {path_} hashes {measured}, name claims {dig}")
            sweep_failed += 1
    if not args.only:
        orphan_paths = [path_ for path_, dig in pairs if dig not in pinned]
        if orphan_paths:
            note("\norphans (store blobs with no pin — listed, never deleted):")
            for o in orphan_paths:
                note(f"  {o}")
    if unparsed:
        note("\nunrecognized files in store (never deleted):")
        for o in unparsed:
            note(f"  {o}")
    if sweep_failed:
        warn(f"audit: {sweep_failed} store sweep failure(s)")
    return 1 if (rc or sweep_failed) else 0


def main():
    ap = argparse.ArgumentParser(description=VERSION)
    ap.add_argument("mode", choices=["ensure", "seal", "audit"])
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--dataDir", required=True)
    ap.add_argument("--store", default="store")
    ap.add_argument("--work", default=".pinwork")
    ap.add_argument("--jobs", type=int, default=min(8, os.cpu_count() or 4))
    ap.add_argument("--only", default="")
    ap.add_argument("--link-owner", default="")
    ap.add_argument("--no-enforce", action="store_true")
    args = ap.parse_args()
    args.enforce = not args.no_enforce
    if args.mode == "ensure":
        return cmd_ensure(args)
    if args.mode == "seal":
        return cmd_seal(args)
    return cmd_audit(args)


if __name__ == "__main__":
    sys.exit(main())
