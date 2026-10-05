"""report_runtime — read-only reporting + update checks for the pin store.

Companion to tools/download_runtime.py: never writes store bytes, never
needs elevated permissions. Reads the pin manifest, the store and the
models tree; the `updates` subcommand additionally queries the civitai
API. The reporting module drops the binary into <store>/bin as a
tmpfiles-managed symlink to this nix-store build (recreated on every
rebuild), so an operator runs, argument-free:

    <store>/nixos-comfyui-tools/comfyui-report report     local classification
    <store>/nixos-comfyui-tools/comfyui-report updates    live civitai checks;
                                                          writes comfyui-updates.md
                                                          and one
                                                          comfyui-updates-<group>.nix
                                                          (lm-parity vs the rest)
                                                          into the current dir
    ...        updates --print-snippets                   + full per-pin listing

Local classification (both subcommands; no re-hashing — blob names carry
their digest, integrity is the audit pass's job):

    current           blob in store + correct symlink at the pin's dest
    adoptable         real file at the dest, hashing to the pin's sha256
    impostor          real file at the dest, hashing to something else
    real-file         real file at the dest, not hashed (--no-hash)
    link-drift        dest/link state the next boot pass repairs without a
                      download (wrong target; dest gone while blob present)
    fetch-pending     bytes exist nowhere local (dest missing or a dangling
                      link with no blob) — the boot pass fetches them
    legacy            legacy real-file pins (unzipInto / non-models dest)
    legacy-mismatch   legacy real-file pin whose dest bytes diverge
    update-orphan     orphan blob whose .pin.json sidecar proves a
                      superseded lineage (same pin id, older civitai
                      versionId than the manifest's)
    unpinned-orphan   orphan blob without a provable lineage; hints name
                      the near-misses (unknown pin id in the sidecar,
                      revision-only drift, sidecar newer than the pin)
    dedup             blobs sharing one digest (one content, several names)
    companion         sidecar-style companion of a model that is present
    companion-orphan  a companion whose model file has vanished
    stray             entries under models/** claimed by no pin
    rot               unexpected entries at the store root (bin/ exempt)

Exit status: 0 when nothing needs hands-on attention, else 1 (impostor /
fetch-pending / legacy-mismatch / rot).

`updates` verdicts per civitai pin: up-to-date, update, drift (same
versionId re-uploaded upstream, hash changed), deleted (version gone from
the model's version list while the page still resolves), not_found, error.
The update candidate is the newest versionId among published versions
sharing the pinned version's baseModel (Lora-Manager-style family
matching: H/L, T2V/I2V or per-character pages on one model stay
"current" instead of recommending a sibling's bytes). When that
candidate is itself pinned elsewhere in the store the pin reads
up-to-date with a note naming the sibling pin. Newer versions on other
base models surface as notes, never verdict changes.
--model-wide-latest restores whole-model latest comparison.
API traffic is paced (--delay, default 2.0 s between requests; Retry-After
honored; 429/5xx backed off exponentially) with one mirror fallback on
403/404 for entries civitai.com masks; tokenized requests go mirror-first
(civitai.red serves the identical API), and the mirror's own 404 is
authoritative — known negatives (hf-only files) cost a single hit. Plus
an optional json response cache (--cache-ttl, default 24 h). Snippets are
printed only from
API-reported primary-file hashes unless --verify downloads and hashes the
candidate first; the boot pass sha-gates the real download either way.

--include-hf is ON by default: huggingface pins resolve against civitai's
by-hash index (--no-include-hf to skip) with the same same-baseModel
logic; "not on civitai by hash" is an up-to-date note and the update
snippet is a full civitaiFetch replacement, marked `# was an hfFetch
pin` in the generated modules. hf identities resolve in batches (up to
100 sha256s per POST against the by-hash index; per-pin GET remains as
a fallback), so an hf sweep costs two lookups, not one per pin. Civitai
pins whose model page is known — an optional `modelId` in the entry, or
the .models-map.json sidecar the tool maintains from its own lookups —
skip the version-id resolution hop entirely. Outputs land as files next
to where the tool runs: comfyui-updates.md
plus one paste-ready comfyui-updates-<category>.nix per non-empty
category — entries grouped exactly like Lora Manager's loras /
checkpoints / embeddings buckets, everything else under "other". The
default is the SAFE path: only clean updates go into the category
modules; anything carrying a verification tell (a candidate shared by
several store pins, or your file being a non-primary member of the
civitai version) is routed to comfyui-updates-verify-first.nix for
inspection instead. .lastrun.json short-circuits same-day reruns (no
rechecking of pins already checked today); --fresh forces a full check.
"""

import argparse
import datetime
import hashlib
import json
import os
import re
import stat
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

VERSION = "report_runtime 1.0"

# Substituted at build time by modules/reporting.nix; both accept
# explicit --manifest / --dataDir overrides.
DEFAULT_MANIFEST = "@MANIFEST@"
DEFAULT_DATA_DIR = "@DATA_DIR@"

EMPTY_SHA = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
BLOB_RE = re.compile(r"^(?P<stem>.+)--(?P<dig>[0-9a-f]{64})(?P<ext>\.[^.]+)?$")

CIVITAI_BASE = "https://civitai.com"
MIRROR_DEFAULT = "civitai.red"
UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36 comfyui-report")

# A file under models/** is a companion when one or more peel steps
# (sidecar markers like .metadata.json, image suffixes, numeric preview
# layers) lead from its name to a pinned dest, another tree entry, or a
# modelish extension.
MODELISH_EXTS = {
    ".safetensors", ".sft", ".ckpt", ".pt", ".pth", ".bin", ".gguf",
    ".onnx", ".vae", ".st", ".lora",
}
_IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".webp", ".mp4", ".gif", ".avif",
               ".txt", ".html"}

NEEDS_ATTENTION = ("impostor", "fetch-pending", "legacy-mismatch", "rot")
DEFAULT_FILTER_CLASSES = (
    "update-orphan,unpinned-orphan,dedup,companion-orphan,stray,rot,"
    "problems"
)
CLASS_ORDER = [
    "current", "adoptable", "link-drift", "fetch-pending", "impostor",
    "real-file", "legacy", "legacy-mismatch", "workflow", "update-orphan",
    "unpinned-orphan", "dedup", "companion", "companion-orphan",
    "baseline", "cache", "stray", "rot",
]
VERDICTS = ["up-to-date", "update", "drift", "deleted", "not_found", "error"]


def _warn(msg):
    print("warn: " + str(msg), file=sys.stderr)


def note(msg):
    print(msg)


def _iso_now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat(
        timespec="seconds")


def _parse_int(value):
    try:
        return int(str(value).strip())
    except (TypeError, ValueError):
        return None


def _human_bytes(count):
    if count is None:
        return "-"
    value = float(count)
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if value < 1024.0 or unit == "TiB":
            if unit == "B":
                return f"{int(value)} {unit}"
            return f"{value:.1f} {unit}"
        value /= 1024.0
    return f"{value} TiB"


def _sha256_file(path):
    digest = hashlib.sha256()
    try:
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                digest.update(chunk)
    except OSError as e:
        _warn(f"hash failed {path}: {e}")
        return None
    return digest.hexdigest()


def _read_token_file(path):
    try:
        with open(path, "rb") as f:
            token = f.read().strip().decode("utf-8", "replace").strip()
        return token or None
    except OSError as e:
        _warn(f"token file unreadable ({path}): {e}")
        return None


def _nix_escape(value):
    return str(value).replace("\\", "\\\\").replace('"', '\\"')


def _md_cell(value):
    return str(value).replace("|", "\\|")


# ---- civitai API client -----------------------------------------------------


class _NoAuthOnRedirect(urllib.request.HTTPRedirectHandler):
    """Redirects that land on a different host must not carry the bearer
    token (civitai download endpoints bounce to their own CDN)."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        request = super().redirect_request(req, fp, code, msg, headers, newurl)
        if request is not None:
            old_host = urllib.parse.urlsplit(req.full_url).netloc
            new_host = urllib.parse.urlsplit(newurl).netloc
            if old_host != new_host:
                for key in list(request.headers):
                    if key.lower() == "authorization":
                        del request.headers[key]
        return request


_OPENER = urllib.request.build_opener(_NoAuthOnRedirect())


class HttpError(Exception):

    def __init__(self, code, retry_after, url):
        super().__init__(f"http {code}: {url}")
        self.code = code
        self.retry_after = retry_after


class Transient(Exception):
    pass


class NotFound(Exception):
    pass


class ApiError(Exception):
    pass


def _http_json(url, token, body=None):
    headers = {"User-Agent": UA}
    data = None
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(url, data=data, headers=headers)
    if token:
        request.add_header("Authorization", "Bearer " + token)
    try:
        with _OPENER.open(request, timeout=45) as response:
            raw = response.read().decode("utf-8")
    except urllib.error.HTTPError as e:
        retry_after = None
        if e.headers is not None:
            retry_after = e.headers.get("Retry-After")
        raise HttpError(e.code, retry_after, url) from None
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        raise Transient(str(e)) from None
    try:
        return json.loads(raw)
    except ValueError as e:
        raise Transient(f"malformed json from {url}: {e}") from None


def _mirror_url(url, mirror):
    parts = urllib.parse.urlsplit(url)
    if not mirror or parts.netloc != "civitai.com":
        return None
    return urllib.parse.urlunsplit(
        (parts.scheme, mirror, parts.path or "/", parts.query, parts.fragment))


class Civitai:
    """Paced, cached json client for the civitai API (one mirror hop)."""

    def __init__(self, delay, mirror, cache_path, cache_ttl_h):
        self.delay = max(0.0, float(delay))
        self.mirror = mirror
        self.cache_path = cache_path
        self.ttl = max(0.0, float(cache_ttl_h)) * 3600.0
        self.cache = self._load_cache()
        self._last = 0.0
        self._dirty = False
        self.hits = 0
        self.fetches = 0

    def _load_cache(self):
        if not self.cache_path:
            return {}
        try:
            with open(self.cache_path) as f:
                doc = json.load(f)
            if isinstance(doc, dict):
                return doc
        except (OSError, ValueError) as e:
            _warn(f"cache ignored ({self.cache_path}): {e}")
        return {}

    def _pace(self):
        wait = self.delay - (time.time() - self._last)
        if wait > 0:
            time.sleep(wait)
        self._last = time.time()

    def pace(self):
        self._pace()

    def get(self, url, token):
        """Paced, cached GET."""
        cached = self.cache.get(url)
        if isinstance(cached, dict) and cached.get("t"):
            fetched = self._age_s(cached["t"])
            if fetched is not None and 0 <= fetched <= self.ttl:
                self.hits += 1
                return cached["doc"]
        return self._fetch(url, token)

    def post(self, url, token, body):
        """Paced POST; not cached (batch payloads vary by body)."""
        return self._fetch(url, token, body=body)

    @staticmethod
    def _age_s(iso):
        try:
            stamp = datetime.datetime.fromisoformat(iso)
        except (TypeError, ValueError):
            return None
        if stamp.tzinfo is None:
            stamp = stamp.replace(tzinfo=datetime.timezone.utc)
        return (datetime.datetime.now(datetime.timezone.utc) - stamp).total_seconds()

    def _fetch(self, url, token, body=None):
        candidates = [url]
        mirrored = _mirror_url(url, self.mirror)
        if mirrored:
            candidates.append(mirrored)
        if token and mirrored:
            # Tokenized requests go mirror-first: civitai.red serves the
            # identical API, and masked/nsfw entries otherwise pay a wasted
            # civitai.com round trip before the fallback fires.
            candidates.reverse()
        saw_4xx = False
        unreachable = False
        for index, candidate in enumerate(candidates):
            attempts = 0
            while True:
                self._pace()
                try:
                    doc = _http_json(candidate, token, body)
                    self.fetches += 1
                    if body is None:
                        self.cache[url] = {"t": _iso_now(), "doc": doc}
                        self._dirty = True
                    return doc
                except HttpError as e:
                    if e.code in (401, 402):
                        raise ApiError(
                            f"http {e.code} — token rejected ({candidate})"
                        ) from None
                    if e.code == 429 or e.code >= 500:
                        if attempts >= 3:
                            unreachable = True
                            break
                        wait = self._backoff_wait(e.retry_after, attempts)
                        _warn(f"api {e.code} {candidate} — retry in {wait:.0f}s")
                        time.sleep(wait)
                        attempts += 1
                        continue
                    saw_4xx = True
                    if index + 1 < len(candidates):
                        fail_host = urllib.parse.urlsplit(candidate).hostname
                        if e.code == 404 and fail_host == self.mirror:
                            # Known negative: the mirror's own 404 is
                            # authoritative; skip the second host.
                            raise NotFound(f"404 on {self.mirror}: {url}")
                        next_host = urllib.parse.urlsplit(
                            candidates[index + 1]).hostname
                        _warn(f"api {e.code} on {fail_host} — trying {next_host}")
                    break
                except (Transient, OSError) as e:
                    if attempts >= 3:
                        unreachable = True
                        break
                    wait = self._backoff_wait(None, attempts)
                    _warn(f"api transient ({e}) {candidate} — retry in {wait:.0f}s")
                    time.sleep(wait)
                    attempts += 1
            if unreachable:
                break
        if saw_4xx:
            raise NotFound(f"403/404 on civitai.com and {self.mirror}: {url}")
        raise ApiError(f"civitai api unreachable after retries: {url}")

    def _backoff_wait(self, retry_after, attempt):
        base = min(60.0, self.delay * (2 ** (attempt + 1)))
        if retry_after:
            try:
                base = max(base, float(retry_after))
            except (TypeError, ValueError):
                pass
        return base

    def head(self, url, token):
        """Advisory reachability probe (status code or None)."""
        self._pace()
        request = urllib.request.Request(url, method="HEAD",
                                         headers={"User-Agent": UA})
        if token:
            request.add_header("Authorization", "Bearer " + token)
        try:
            with _OPENER.open(request, timeout=45) as response:
                return response.status
        except urllib.error.HTTPError as e:
            return e.code
        except (urllib.error.URLError, TimeoutError, OSError):
            return None

    def flush(self):
        if not (self.cache_path and self._dirty):
            return
        try:
            os.makedirs(os.path.dirname(self.cache_path), exist_ok=True)
            tmp = self.cache_path + "." + str(os.getpid()) + ".tmp"
            with open(tmp, "w") as f:
                json.dump(self.cache, f)
            os.replace(tmp, self.cache_path)
        except OSError as e:
            _warn("cache write failed: " + str(e))


def _default_cache_path():
    try:
        base = os.environ.get("XDG_CACHE_HOME") or os.path.join(
            os.path.expanduser("~"), ".cache")
    except (KeyError, RuntimeError, OSError):
        return None
    return os.path.join(base, "comfyui-report", "civitai-cache.json")


# ---- manifest + local state -------------------------------------------------


class PinStore:
    """The resolved pin manifest plus the on-disk state it describes."""

    def __init__(self, manifest_path, data_dir):
        if not manifest_path or not os.path.isfile(manifest_path):
            raise SystemExit(
                f"manifest not found: {manifest_path or '(none)'} — pass "
                "--manifest, or rebuild so the reporting module bakes the "
                "path in")
        if not data_dir:
            raise SystemExit("no dataDir — pass --dataDir")
        self.manifest_path = manifest_path
        self.data_dir = os.path.abspath(data_dir)
        self.pins = []
        self.models = []
        self.workflows = []
        self.legacy = []
        self.dests = {}
        self.pins_by_id = {}
        with open(manifest_path) as f:
            rows = json.load(f)
        for raw in rows:
            raw.setdefault("provenance", {})
            self.pins.append(raw)
            self.pins_by_id[raw.get("id")] = raw
            dest = raw.get("dest") or ""
            if dest:
                self.dests.setdefault(dest, raw)
            if raw.get("kind") == "workflow":
                self.workflows.append(raw)
            elif raw.get("legacy"):
                self.legacy.append(raw)
            else:
                self.models.append(raw)

    def scan_store(self):
        store_dir = os.path.join(self.data_dir, "store")
        state = {
            "store_dir": store_dir,
            "exists": os.path.isdir(store_dir),
            "blobs": [],
            "by_name": {},
            "by_digest": {},
            "sidecars": {},
            "rot": [],
        }
        if not state["exists"]:
            return state
        for name in sorted(os.listdir(store_dir)):
            path = os.path.join(store_dir, name)
            if name == "bin" or name == "README.md":
                continue
            if not os.path.isfile(path):
                state["rot"].append({"path": name, "kind": "unexpected directory"})
                continue
            if name.endswith(".pin.json"):
                base = name[: -len(".pin.json")]
                try:
                    with open(path) as f:
                        state["sidecars"][base] = json.load(f)
                except (OSError, ValueError) as e:
                    _warn(f"unparseable sidecar {name}: {e}")
                    state["sidecars"][base] = None
                continue
            match = BLOB_RE.match(name)
            if not match:
                state["rot"].append({"path": name, "kind": "unrecognized file"})
                continue
            blob = {
                "name": name,
                "path": path,
                "dig": match.group("dig"),
                "size": os.path.getsize(path),
            }
            state["blobs"].append(blob)
            state["by_name"][name] = blob
            state["by_digest"].setdefault(blob["dig"], []).append(blob)
        for base in sorted(state["sidecars"]):
            if base not in state["by_name"]:
                state["rot"].append({
                    "path": base + ".pin.json",
                    "kind": "sidecar without its blob",
                })
        return state

    def scan_models_tree(self):
        root = os.path.join(self.data_dir, "models")
        tree = {}
        if not os.path.isdir(root):
            return tree
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames.sort()
            for name in sorted(filenames):
                path = os.path.join(dirpath, name)
                try:
                    rel = os.path.relpath(path, self.data_dir).replace(os.sep, "/")
                    tree[rel] = self._tree_state(path)
                except OSError as e:
                    _warn(f"unreadable {path}: {e}")
        return tree

    @staticmethod
    def _tree_state(path):
        st = os.lstat(path)
        if stat.S_ISLNK(st.st_mode):
            target = os.readlink(path)
            abs_target = target
            if not os.path.isabs(abs_target):
                abs_target = os.path.normpath(
                    os.path.join(os.path.dirname(path), target))
            return {
                "kind": "link",
                "target": abs_target,
                "broken": not os.path.exists(abs_target),
            }
        if stat.S_ISREG(st.st_mode):
            return {"kind": "real", "size": st.st_size}
        return {"kind": "other"}


def _same_path(a, b):
    try:
        return (os.path.normpath(os.path.abspath(a)) == os.path.normpath(os.path.abspath(b)))
    except OSError:
        return a == b


def _peel_candidates(name):
    """Candidate bases for a companion file: peel marker/image/numeric
    layers off the filename ("X.safetensors.metadata.json" ->
    "X.safetensors", "X.safetensors.1.jpeg" -> "X.safetensors")."""
    out = []
    cur = name
    for _ in range(5):
        stem, ext = os.path.splitext(cur)
        low = ext.lower()
        if low == ".json":
            cur = stem
            if cur.endswith(".metadata"):
                cur = cur[: -len(".metadata")]
            elif cur.endswith(".civitai"):
                cur = cur[: -len(".civitai")]
            out.append(cur)
        elif low == ".info":
            cur = stem
            if cur.endswith(".civitai"):
                cur = cur[: -len(".civitai")]
            out.append(cur)
        elif low == ".preview":
            cur = stem
            out.append(cur)
        elif low in _IMAGE_EXTS:
            cur = stem
            out.append(cur)
        elif re.fullmatch(r"\.\d+", ext):
            cur = stem
            out.append(cur)
        else:
            break
    return [c for c in out if c]


def _companion_of(rel, dests, tree, dest_by_base, tree_by_base):
    """Base path this file is a sidecar of, probing all peeled bases:
    direct hit in dests/tree, the same basename elsewhere (models move,
    sidecars can be left behind), a modelish extension on the base, or
    base + one of the modelish extensions."""
    for base in _peel_candidates(rel):
        if base in dests or base in tree:
            return base
        base_bn = base.rsplit("/", 1)[-1]
        if base_bn in tree_by_base:
            return tree_by_base[base_bn][0]
        if base_bn in dest_by_base:
            return dest_by_base[base_bn]
        if os.path.splitext(base)[1].lower() in MODELISH_EXTS:
            return base
        for modelish in sorted(MODELISH_EXTS):
            if base + modelish in dests or base + modelish in tree:
                return base + modelish
            if base_bn + modelish in tree_by_base:
                return tree_by_base[base_bn + modelish][0]
            if base_bn + modelish in dest_by_base:
                return dest_by_base[base_bn + modelish]
    return None


def classify_local(pins, store, tree, hash_real=True):
    """Both subcommands' classification of the LOCAL state. Pin rows come
    from pins.models; orphans/dedup/tree classes always use the full
    claim sets so --only cannot manufacture orphans."""
    classes = {}

    def put(cls, row):
        classes.setdefault(cls, []).append(row)

    for w in pins.workflows:
        put("workflow", {"pin": w["id"], "dest": w.get("dest") or ""})

    pinned_digs = set()
    for p in pins.models + pins.legacy:
        sha = (p.get("sha256") or "").strip().lower()
        if len(sha) == 64 and sha != EMPTY_SHA:
            pinned_digs.add(sha)

    dest_by_base = {}
    for dest in pins.dests:
        dest_by_base.setdefault(dest.rsplit("/", 1)[-1], dest)
    tree_by_base = {}
    for rel in tree:
        tree_by_base.setdefault(rel.rsplit("/", 1)[-1], []).append(rel)

    for p in pins.models:
        dest = p.get("dest") or ""
        sha = (p.get("sha256") or "").strip().lower()
        blob_paths = [b["path"] for b in store["by_digest"].get(sha, [])]
        blob0 = blob_paths[0] if blob_paths else None
        base = {"pin": p["id"], "dest": dest}
        dst = tree.get(dest)
        if dst is None:
            if blob0:
                put("link-drift", dict(base, reason=(
                    "dest absent, blob present — next boot pass relinks")))
            else:
                put("fetch-pending", dict(base, reason=(
                    "dest and blob absent — next boot pass fetches")))
            continue
        if dst["kind"] == "link":
            target = dst["target"]
            if blob0 and _same_path(target, blob0):
                put("current", base)
            elif dst["broken"]:
                if blob0:
                    put("link-drift", dict(base, reason=(
                        f"dangling link -> {target}; blob present — relink")))
                else:
                    put("fetch-pending", dict(base, reason=(
                        f"dangling link -> {target}; no blob — will fetch")))
            else:
                put("link-drift", dict(base, reason=(
                    f"symlink -> {target} (wrong target)")))
            continue
        if dst["kind"] == "real":
            if hash_real:
                dig = _sha256_file(os.path.join(pins.data_dir, dest))
                if dig == sha:
                    put("adoptable", dict(base, bytes=dst.get("size")))
                else:
                    put("impostor", dict(base, found=dig or "(unreadable)"))
            else:
                put("real-file", dict(base, bytes=dst.get("size")))
            continue
        put("impostor", dict(base, reason="non-regular object at dest"))

    for p in pins.legacy:
        dest = p.get("dest") or ""
        path = os.path.join(pins.data_dir, dest)
        sha = (p.get("sha256") or "").strip().lower()
        base = {"pin": p["id"], "dest": dest}
        if not os.path.isfile(path):
            put("fetch-pending", dict(base, reason=(
                "legacy dest absent — boot pass fetches")))
        elif hash_real:
            dig = _sha256_file(path)
            if dig == sha:
                put("legacy", base)
            else:
                put("legacy-mismatch", dict(base, found=dig or "(unreadable)"))
        else:
            put("legacy", base)

    for blob in store["blobs"]:
        if blob["dig"] in pinned_digs:
            continue
        row = {
            "blob": blob["name"],
            "path": blob["path"],
            "bytes": blob["size"],
        }
        side = store["sidecars"].get(blob["name"])
        pin_id = side.get("pin") if isinstance(side, dict) else None
        mrow = pins.pins_by_id.get(str(pin_id)) if pin_id else None
        mprov = (mrow or {}).get("provenance") or {}
        svid = _parse_int(side.get("versionId")) if isinstance(side, dict) else None
        mvid = _parse_int(mprov.get("versionId"))
        if pin_id and mrow:
            row["pin"] = pin_id
            if mprov.get("source") == "civitai" and side.get("source") == "civitai":
                if mvid is not None and svid is not None and mvid > svid:
                    row["versionId"] = svid
                    row["supersededBy"] = mvid
                    put("update-orphan", row)
                elif mvid is not None and svid is not None and svid > mvid:
                    row["hint"] = "sidecar version is NEWER than the pin's (rolled back?)"
                    put("unpinned-orphan", row)
                else:
                    row["hint"] = "same versionId as the pin but different bytes"
                    put("unpinned-orphan", row)
            else:
                row["hint"] = "pin id matches, but its lineage is not version-comparable"
                put("unpinned-orphan", row)
        elif pin_id and not mrow:
            row["hint"] = f"sidecar names pin '{pin_id}', which is not in the manifest"
            put("unpinned-orphan", row)
        elif pin_id:
            row["hint"] = "sidecar present but unreadable"
            put("unpinned-orphan", row)
        else:
            row["hint"] = "grandfathered: no pin in sidecar"
            put("unpinned-orphan", row)

    for dig, blobs in sorted(store["by_digest"].items()):
        if len(blobs) > 1:
            put("dedup", {
                "sha": dig,
                "blobs": [b["name"] for b in blobs],
                "bytes": blobs[0]["size"],
            })

    for rel in sorted(tree):
        if rel in pins.dests:
            continue
        dst = tree[rel]
        if "/.cache/" in "/" + rel:
            put("cache", {"path": rel, "bytes": dst.get("size")})
            continue
        base_name = rel.rsplit("/", 1)[-1]
        dir_name = rel.rsplit("/", 1)[0]
        is_placeholder = base_name.startswith("put_") and base_name.endswith("_here")
        is_config_yaml = base_name.endswith(".yaml") and dir_name.endswith("configs")
        if is_placeholder or is_config_yaml:
            put("baseline", {"path": rel, "bytes": dst.get("size")})
            continue
        base = _companion_of(rel, pins.dests, tree, dest_by_base, tree_by_base)
        if base is not None:
            if base in pins.dests or base in tree:
                put("companion", {"path": rel, "of": base, "bytes": dst.get("size")})
            else:
                put("companion-orphan", {"path": rel, "of": base})
        elif dst["kind"] == "real":
            put("stray", {"path": rel, "kind": "real file", "bytes": dst.get("size")})
        elif dst["kind"] == "link":
            put("stray", {"path": rel, "kind": "link", "broken": dst["broken"],
                          "target": dst["target"]})
        else:
            put("stray", {"path": rel, "kind": "non-regular entry"})
    return classes


def resolve_filter(filters):
    if not filters:
        return [c for c in CLASS_ORDER if c in [
            "update-orphan", "unpinned-orphan", "dedup",
            "companion-orphan", "stray", "rot", "impostor",
            "fetch-pending", "legacy-mismatch",
        ]]
    selected = []
    for raw in filters:
        for part in str(raw).split(","):
            part = part.strip()
            if not part:
                continue
            if part == "all":
                return list(CLASS_ORDER)
            if part == "problems":
                for cls in NEEDS_ATTENTION:
                    if cls not in selected:
                        selected.append(cls)
                continue
            if part not in selected:
                selected.append(part)
            if part not in CLASS_ORDER:
                _warn(f"unknown class '{part}' (known: {', '.join(CLASS_ORDER)})")
    return selected


def _summarize(classes):
    summary = {}
    for cls in CLASS_ORDER:
        rows = classes.get(cls)
        if rows is None:
            continue
        summary[cls] = {
            "count": len(rows),
            "bytes": _or_none(sum(r.get("bytes") or 0 for r in rows)),
        }
    return summary


def _or_none(value):
    return value or None


def _detail_line(cls, row):
    if cls == "current":
        return f"  {row['dest']}"
    if cls == "adoptable":
        return (f"  {row['dest']}  ({_human_bytes(row.get('bytes'))}) — "
                "hashes to its pin; next boot pass adopts it as the blob")
    if cls == "impostor":
        extra = row.get("reason") or f"hashes {_short(row.get('found'))}"
        return f"  {row['dest']}  — drifted: {extra}; " \
               "boot pass parks + replaces after a verified fetch"
    if cls == "real-file":
        return (f"  {row['dest']}  ({_human_bytes(row.get('bytes'))}) — "
                "not hashed (--no-hash)")
    if cls in ("link-drift", "fetch-pending"):
        return f"  {row['dest']}  — {row.get('reason')}"
    if cls in ("legacy", "legacy-mismatch"):
        extra = "" if cls == "legacy" else f" — hashes {_short(row.get('found'))}"
        return f"  {row['dest']} (legacy pin){extra}"
    if cls == "workflow":
        return f"  {row['pin']}: {row['dest']}"
    if cls == "update-orphan":
        return (f"  {row['blob']}  ({_human_bytes(row.get('bytes'))}) "
                f"pin={row['pin']} v{row['versionId']} superseded by "
                f"v{row['supersededBy']}")
    if cls == "unpinned-orphan":
        hint = row.get("hint") or ""
        return (f"  {row['blob']}  ({_human_bytes(row.get('bytes'))}) "
                f"{hint}")
    if cls == "dedup":
        return (f"  {_short(row['sha'])}  {', '.join(row['blobs'])} — "
                "one content, several names")
    if cls == "companion":
        return f"  {row['path']}  ->  {row['of']}"
    if cls == "companion-orphan":
        return f"  {row['path']}  ->  {row['of']} (vanished)"
    if cls == "stray":
        extra = f", {_human_bytes(row.get('bytes'))}" if row.get("bytes") else ""
        extra += " — dangling" if row.get("broken") else ""
        target_part = f"  ->  {row['target']}" if row.get("target") else ""
        return f"  {row['path']}  ({row.get('kind')}{extra}){target_part}"
    if cls == "rot":
        return f"  {row['path']}: {row['kind']}"
    return f"  {row}"


def _short(digest_or_none):
    if not digest_or_none:
        return "(none)"
    return digest_or_none[:12] + "…"


def _print_report(pins, store, classes, selected):
    model_n = len(pins.models)
    total_bytes = sum(b["size"] for b in store["blobs"])
    note(f"pin-store report — {pins.data_dir}")
    note(
        f"manifest: {pins.manifest_path} "
        f"({len(pins.pins)} pins: {model_n} model, {len(pins.workflows)} "
        f"workflow, {len(pins.legacy)} legacy)"
    )
    note(f"store: {_plural(len(store['blobs']), 'blob')} ({_human_bytes(total_bytes)})")
    summary = _summarize(classes)
    note("")
    note(f"{'class':16} {'count':>6}  bytes")
    for cls in CLASS_ORDER:
        if cls in summary:
            row = summary[cls]
            note(f"{cls:16} {row['count']:>6}  {_human_bytes(row['bytes'])}")
    note("")
    for cls in selected:
        rows = classes.get(cls)
        if not rows:
            continue
        note(f"{cls} ({len(rows)}):")
        for row in rows:
            note(_detail_line(cls, row))
        note("")


def _plural(n, word):
    plural = "es" if word.endswith("s") else "s"
    return f"{n} {word}{'' if n == 1 else plural}"


def _write_report_md(path, pins, store, classes, selected):
    lines = ["# Pin-store report", ""]
    lines.append(f"- dataDir: `{pins.data_dir}`")
    lines.append(
        f"- manifest: `{pins.manifest_path}` "
        f"({_plural(len(pins.pins), 'pin')}: {len(pins.models)} model, "
        f"{len(pins.workflows)} workflow, {len(pins.legacy)} legacy)"
    )
    total_bytes = sum(b["size"] for b in store["blobs"])
    lines.append(
        f"- store: {_plural(len(store['blobs']), 'blob')} "
        f"({_human_bytes(total_bytes)})"
    )
    lines.append(f"- generated: {_iso_now()}")
    lines += ["", "## summary", "", "| class | count | bytes |",
              "|---|---:|---:|"]
    for cls, row in _summarize(classes).items():
        lines.append(
            f"| {cls} | {row['count']} | {_human_bytes(row['bytes'])} |")
    for cls in selected:
        rows = classes.get(cls)
        if not rows:
            continue
        lines += ["", f"## {cls} ({len(rows)})", ""]
        for row in rows:
            lines.append("- " + _md_cell(
                _detail_line(cls, row).strip().lstrip("- ")))
    _atomic_write(path, "\n".join(lines) + "\n")
    note(f"md written: {path}")


def _atomic_write(path, text):
    parent = os.path.dirname(os.path.abspath(path))
    os.makedirs(parent, exist_ok=True)
    tmp = path + f".{os.getpid()}.tmp"
    with open(tmp, "w") as f:
        f.write(text)
    os.replace(tmp, path)


def cmd_report(args):
    pins = PinStore(args.manifest, args.dataDir)
    store = pins.scan_store()
    tree = pins.scan_models_tree()
    classes = classify_local(pins, store, tree, hash_real=not args.no_hash)
    selected = resolve_filter(args.filter)
    if args.json:
        payload = {
            "version": VERSION,
            "generated_at": _iso_now(),
            "dataDir": pins.data_dir,
            "manifest": pins.manifest_path,
            "summary": _summarize(classes),
            "rows": {cls: classes.get(cls, []) for cls in CLASS_ORDER},
        }
        print(json.dumps(payload, indent=1, sort_keys=True))
    if args.md:
        _write_report_md(args.md, pins, store, classes, selected)
    if args.json or args.md:
        return _attention_rc(classes)
    _print_report(pins, store, classes, selected)
    return _attention_rc(classes)


def _attention_rc(classes):
    for cls in NEEDS_ATTENTION:
        if classes.get(cls):
            return 1
    return 0


# ---- updates ----------------------------------------------------------------


def _primary_file(version_row):
    files = (version_row or {}).get("files") or []
    for f in files:
        if f.get("primary"):
            return f
    return files[0] if files else None


def _file_sha(file_row):
    hashes = (file_row or {}).get("hashes") or {}
    sha = str(hashes.get("SHA256") or "").strip().lower()
    return sha or None


def _file_bytes(file_row):
    kb = (file_row or {}).get("sizeKB")
    value = _parse_int(kb)
    if value is None:
        return None
    return int(round(float(kb) * 1024))


def progress(args, msg):
    print(msg, file=sys.stderr)


def _verify_candidate(cand, token, args):
    url = cand.get("downloadUrl")
    if not url:
        return None, "candidate exposes no downloadUrl — cannot verify"
    base_dir = args.verify_dir or tempfile.gettempdir()
    ext = os.path.splitext(str(cand.get("fileName") or ""))[1] or ".bin"
    part = os.path.join(
        base_dir, "comfyui-verify-" + str(cand.get("sha"))[:16] + ext + ".part")
    request = urllib.request.Request(url, headers={"User-Agent": UA})
    if token:
        request.add_header("Authorization", "Bearer " + token)
    progress(args, f"    verifying: streaming {cand.get('fileName')} ...")
    digest = hashlib.sha256()
    try:
        with _OPENER.open(request, timeout=180) as response, \
                open(part, "wb") as fh:
            total = 0
            while True:
                chunk = response.read(1 << 20)
                if not chunk:
                    break
                fh.write(chunk)
                digest.update(chunk)
                previous = total // (1 << 30)
                total += len(chunk)
                if total // (1 << 30) != previous and total > 0:
                    progress(args, f"    verifying... {_human_bytes(total)}")
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        try:
            os.remove(part)
        except OSError:
            pass
        return None, "verify download failed: " + str(e)
    measured = digest.hexdigest()
    if args.keep_verified:
        kept = part[: -len(".part")]
        try:
            os.replace(part, kept)
            progress(args, "    verified bytes kept: " + kept)
        except OSError as e:
            _warn(f"could not keep verified bytes: {e}")
    else:
        try:
            os.remove(part)
        except OSError:
            pass
    return measured, None


def _snippet(pin, cand, verified, keep_name):
    pin_id = _nix_escape(pin["id"])
    dest = pin.get("dest") or ""
    sha = str(cand.get("sha") or "")
    if verified:
        note_sha = "sha256: measured from a verified download"
    else:
        note_sha = "sha256: api-reported; the boot pass sha-gates the download"
    version_part = (f"v{cand['versionId']}"
                    if cand.get("versionId") else "(unknown)")
    verified_part = "  [verified]" if verified else ""
    header = (
        f"      # {pin['id']}: {version_part}"
        f" ({cand.get('date') or 'no date'})"
        f"  {_human_bytes(cand.get('bytes'))}"
        f"{verified_part}"
        f"  {note_sha}"
    )
    lines = [header]
    lines.append(f'      "{pin_id}" = civitaiFetch {{')
    if cand.get("versionId"):
        lines.append(f"        versionId = {cand['versionId']};")
    if cand.get("fileId"):
        lines.append("        fileId = %d;" % int(cand["fileId"]))
    if cand.get("modelId"):
        lines.append("        modelId = %d;" % int(cand["modelId"]))
    lines.append(f'        sha256 = "{sha}";')
    if dest.startswith("models/"):
        parts = dest[len("models/"):].split("/")
        lines.append(f"        type = \"{_nix_escape(parts[0])}\";")
        arch = parts[1:-1]
        if arch:
            entries = " ".join("\"" + _nix_escape(a) + "\"" for a in arch)
            lines.append(f"        arch = [ {entries} ];")
        if keep_name:
            local_name = parts[-1]
        else:
            local_name = cand.get("fileName") or parts[-1]
        lines.append(f"        name = \"{_nix_escape(local_name)}\";")
    else:
        lines.append(f"        dest = \"{_nix_escape(dest)}\";")
        if pin.get("unzipInto"):
            lines.append(f"        unzipInto = \"{_nix_escape(pin['unzipInto'])}\";")
    lines.append("      };")
    return "\n".join(lines)


def _blank_result(pin, store):
    """Result skeleton shared by the civitai and hf checkers."""
    pin_sha = (pin.get("sha256") or "").strip().lower()
    return {
        "pin": pin["id"],
        "dest": pin.get("dest") or "",
        "verdict": "error",
        "source": None,
        "in_store": bool(store["by_digest"].get(pin_sha)) if pin_sha else False,
        "local_sha": pin_sha or None,
        "pinned": None,
        "candidate": None,
        "model": None,
        "note": None,
        "tell": None,
        "snippet": None,
    }


def _check_civitai_pin(api, pin, token, store, args, sibling_pins=None,
                       models_map=None):
    """Check one civitai pin; sibling_pins maps versionId -> pin ids.
    models_map: mutable {versionId: modelId} sidecar — a pin whose model
    page is recorded (manifest provenance or sidecar) skips the version-
    id resolution hop entirely; fresh lookups backfill the sidecar."""
    sibling_pins = sibling_pins or {}
    prov = pin.get("provenance") or {}
    vid = str(prov.get("versionId") or "")
    result = _blank_result(pin, store)
    result["source"] = "civitai"
    mid = _parse_int(prov.get("modelId"))
    if mid is None and models_map is not None:
        mid = models_map.get(vid)
    vdoc = None
    if mid is not None:
        vdoc = {"modelId": mid}
    else:
        try:
            vdoc = api.get(CIVITAI_BASE + "/api/v1/model-versions/" + vid,
                           token)
        except NotFound as e:
            return dict(result, verdict="not_found",
                        note=f"version {vid}: {e}")
        except ApiError as e:
            return dict(result, note=str(e))
        mid = _parse_int(vdoc.get("modelId"))
        if models_map is not None and mid:
            models_map[vid] = mid
    try:
        mdoc = api.get(CIVITAI_BASE + "/api/v1/models/" + str(mid), token)
    except NotFound:
        return dict(result, verdict="not_found",
                    note=f"model {mid} is gone while its version endpoint works")
    except ApiError as e:
        return dict(result, note=str(e))
    return _assess_version(result, pin, vid, vdoc, mdoc, token, args,
                           sibling_pins, "civitai")


def _check_hf_pin(api, pin, token, store, args, sibling_pins=None, resolved=None):
    """Check a huggingface pin: identity from civitai's by-hash index,
    then the same family logic as civitai pins. No sha256 -> HEAD probe.
    resolved = {"hits": {sha: version-doc}, "misses": {sha}} from batched
    lookups; a sha in neither set falls back to the per-pin GET."""
    sibling_pins = sibling_pins or {}
    result = _blank_result(pin, store)
    result["source"] = "huggingface"
    sha = (pin.get("sha256") or "").strip().lower()
    negative = dict(result, verdict="up-to-date",
                    note="not on civitai by hash — no mirror to track; "
                         "the hf rev governs")
    if not sha:
        urls = pin.get("urls") or []
        url = urls[0] if urls else None
        if not url:
            return dict(result, verdict="not_found",
                        note="no sha256 and no resolve url to probe")
        hf_token = _read_token(pin.get("tokenFile"), {})
        code = api.head(url, hf_token)
        if code in (200, 301, 302, 303, 307, 308):
            return dict(result, verdict="up-to-date",
                        note="no sha256; upstream HEAD alive")
        if code in (404, 410):
            return dict(result, verdict="not_found",
                        note=f"upstream gone — resolve url answers {code}")
        return dict(result, note=f"HEAD answered {code}")
    vdoc = None
    if resolved is not None:
        hit = resolved.get("hits", {}).get(sha)
        if hit is not None:
            vdoc = hit
        elif sha in resolved.get("misses", ()):
            return negative
    if vdoc is None:
        by_hash_url = CIVITAI_BASE + "/api/v1/model-versions/by-hash/" + sha
        try:
            vdoc = api.get(by_hash_url, token)
        except NotFound:
            return negative
        except ApiError as e:
            return dict(result, note=str(e))
    mid = vdoc.get("modelId")
    if mid is None:
        return dict(result, note="by-hash matched but the version exposes no modelId")
    try:
        mdoc = api.get(CIVITAI_BASE + "/api/v1/models/" + str(mid), token)
    except NotFound:
        return dict(result, verdict="not_found",
                    note=f"civitai model {mid} is gone")
    except ApiError as e:
        return dict(result, note=str(e))
    return _assess_version(result, pin, str(vdoc.get("id") or ""), vdoc, mdoc,
                           token, args, sibling_pins, "huggingface")


def _member_named(version_row, base_name):
    """The version's Model file whose basename matches base_name (case-
    insensitive), else None — our bytes' counterpart in a version."""
    if not base_name:
        return None
    base = os.path.basename(base_name).lower()
    for f in (version_row.get("files") or []):
        if f.get("type") != "Model":
            continue
        fname = os.path.basename(str(f.get("name") or ""))
        if fname.lower() == base:
            return f
    return None


def _assess_version(result, pin, vid, vdoc, mdoc, token, args, sibling_pins,
                    source):
    """Family logic shared by civitai pins and hf (by-hash) identities."""
    sibling_pins = sibling_pins or {}
    pin_sha = result.get("local_sha") or ""
    mid = vdoc.get("modelId")
    model_row = {
        "id": mid,
        "name": mdoc.get("name"),
        "url": f"{CIVITAI_BASE}/models/{mid}",
    }
    rows = mdoc.get("modelVersions") or []
    published = [v for v in rows if v.get("publishedAt")]
    pinned_row = None
    for v in rows:
        if str(v.get("id")) == vid:
            pinned_row = v
            break
    if pinned_row is None:
        if source != "civitai":
            return dict(result, verdict="up-to-date", model=model_row,
                        note=("civitai version {} is no longer in the model's "
                              "version list (removed/unpublished); the "
                              "matched hash still identifies it".format(vid)))
        return dict(result, verdict="deleted", model=model_row,
                    note=(f"version {vid} no longer in the model's version "
                          f"list; the store blob is the local copy"))
    pinned_file = _primary_file(pinned_row)
    hf_matched_name = None
    if source != "civitai":
        for f in (pinned_row.get("files") or []):
            if (_file_sha(f) or "").lower() == pin_sha:
                hf_matched_name = (f or {}).get("name")
                break
    result["pinned"] = {
        "versionId": vid,
        "baseModel": pinned_row.get("baseModel") or None,
        "date": str(pinned_row.get("publishedAt") or "")[:10],
        "sha": _file_sha(pinned_file),
        "bytes": _file_bytes(pinned_file),
        "fileName": hf_matched_name or (pinned_file or {}).get("name"),
    }
    # Candidate selection: newest versionId on the pinned version's own
    # baseModel when known (Lora-Manager-style family matching), else the
    # model-wide (publishedAt, id) latest. VersionId order is deliberate:
    # ids follow upload order, and publish dates invert on H/L re-uploads.
    pinned_base = str(pinned_row.get("baseModel") or "").strip().lower()
    use_base = bool(pinned_base) and not getattr(args, "model_wide_latest", False)
    other_base = []
    latest = None
    if use_base:
        pinned_int = _parse_int(vid) or 0
        for v in published:
            v_int = _parse_int(v.get("id")) or 0
            if str(v.get("baseModel") or "").strip().lower() == pinned_base:
                if latest is None or v_int > (_parse_int(latest.get("id")) or 0):
                    latest = v
            elif v_int > pinned_int:
                other_base.append((v_int, v.get("baseModel")))
        other_base.sort(key=lambda pair: -pair[0])
    else:
        latest_key = None
        for v in published:
            key = (str(v.get("publishedAt") or ""), _parse_int(v.get("id")) or 0)
            if latest is None or key > latest_key:
                latest = v
                latest_key = key
    cand_row = pinned_row
    verdict = "up-to-date"
    note_txt = None
    if latest is not None and str(latest.get("id")) != vid:
        sibs = [s for s in sorted(sibling_pins.get(_parse_int(latest.get("id")), []))
                if s != pin["id"]]
        if use_base and sibs:
            # The family's newest same-base version is another pin here —
            # current for its purpose (Lora-Manager's is_in_library rule).
            note_txt = (
                "newest same-base version v{} is pinned as {} — variant "
                "family current".format(latest.get("id"), ", ".join(sibs)))
        else:
            verdict = "update"
            cand_row = latest
    trailing = None
    if use_base and other_base:
        shown = ("v{} ({})".format(v_int, v_base or "?")
                 for v_int, v_base in other_base[:3])
        extra = " (+{} more)".format(len(other_base) - 3) if len(other_base) > 3 else ""
        trailing = "newer versions on other base models: {}{}".format(
            ", ".join(shown), extra)
    # Our bytes' member on each version: the pin's own provenance file
    # (civitai), the by-hash matched file (hf), else the primary. Update
    # candidates target the SAME-NAMED member of the candidate version —
    # multi-file versions (gguf quant flips, vae/encoder bundles) then
    # upgrade the right member instead of adopting a different file type.
    pin_member_name = os.path.basename(str((pin.get("provenance") or {}).get("file") or hf_matched_name or (pinned_file or {}).get("name") or ""))
    pin_member = _member_named(pinned_row, pin_member_name) or pinned_file
    cand_sha = _file_sha(pin_member)
    same_verdict = verdict == "up-to-date"
    sha_differs = bool(cand_sha) and bool(pin_sha) and cand_sha != pin_sha
    if same_verdict and source == "civitai" and sha_differs:
        verdict = "drift"
    cand_file = _member_named(cand_row, pin_member_name)
    cand_member = cand_file is not None
    if not cand_member:
        cand_file = _primary_file(cand_row)
    hf_note = None
    if hf_matched_name and hf_matched_name != (pinned_file or {}).get("name"):
        if cand_member:
            hf_note = ("your file is a non-primary member — the update targets "
                       "the candidate's same-named member")
        else:
            result["tell"] = "; ".join(x for x in (
                result.get("tell"),
                "your file is a non-primary member of the civitai version — "
                "the candidate replaces the version's primary") if x)
            hf_note = ("your file is '{}' on this civitai version (primary: "
                       "'{}')".format(hf_matched_name,
                                      (pinned_file or {}).get("name")))
    cand = {
        "versionId": str(cand_row.get("id")),
        "fileId": _parse_int((cand_file or {}).get("id")),
        "modelId": mid,
        "baseModel": cand_row.get("baseModel") or None,
        "date": str(cand_row.get("publishedAt") or "")[:10],
        "sha": _file_sha(cand_file),
        "bytes": _file_bytes(cand_file),
        "fileName": (cand_file or {}).get("name"),
        "downloadUrl": (cand_file or {}).get("downloadUrl"),
        "changelog": str(cand_row.get("changelog") or ""),
    }
    notes = [n for n in (note_txt, trailing, hf_note) if n]
    if notes:
        result["note"] = "; ".join(notes)
    if cand_member is False and verdict == "update" and (cand.get("fileName") or ""):
        cand_ext = os.path.splitext(str(cand["fileName"]).lower())[1]
        dest_ext = os.path.splitext(os.path.basename(str(result["dest"] or "")).lower())[1]
        if cand_ext and dest_ext and cand_ext != dest_ext:
            result["tell"] = "; ".join(x for x in (
                result.get("tell"),
                "the candidate's primary is a '{}' while your dest is a '{}' "
                "— resolve the matching member before pasting".format(
                    cand_ext, dest_ext)) if x)
    result.update(verdict=verdict, source=source, model=model_row,
                  candidate=cand)
    if verdict in ("update", "drift"):
        if not cand.get("sha"):
            prior = result.get("note")
            msg = "candidate has no SHA256 in the api response"
            if prior:
                msg = msg + "; " + prior
            result["note"] = msg
            return result
        if args.verify:
            measured, verify_note = _verify_candidate(cand, token, args)
            if verify_note:
                return dict(result, note=verify_note)
            if measured != cand["sha"]:
                return dict(result, note=(
                    f"verify mismatch: serving bytes hash {measured}, "
                    f"api claims {cand['sha']}"))
            cand["measured"] = measured
            result["candidate"] = cand
        result["snippet"] = _snippet(
            pin, cand, verified=bool(cand.get("measured")),
            keep_name=not args.follow_upstream_names)
    return result


def _resolve_targets(pins, only):
    tallies = {"hf": 0, "other": 0}
    targets = []
    for p in pins.models:
        prov = p.get("provenance") or {}
        source = prov.get("source")
        wanted = True
        if only and only.lower() not in str(p.get("id", "")).lower():
            wanted = False
        if source == "civitai":
            if wanted:
                targets.append(p)
        elif source == "huggingface":
            tallies["hf"] += 1
        else:
            tallies["other"] += 1
    return targets, tallies


def _read_token(path, cache):
    if not path:
        return None
    if path not in cache:
        cache[path] = _read_token_file(path)
    return cache[path]


def _print_updates(results, args):
    counts = {}
    for r in results:
        counts[r["verdict"]] = counts.get(r["verdict"], 0) + 1
    summary = ", ".join(f"{v} {counts[v]}" for v in VERDICTS if counts.get(v))
    note(f"civitai update check: {summary or 'nothing checked'}")
    note("")
    for r in results:
        verdict = r["verdict"]
        if verdict == "up-to-date" and not args.all:
            continue
        name = os.path.basename(r["dest"]) or r["dest"]
        store_note = "  [in store]" if r.get("in_store") else ""
        note(f"{verdict:10} {r['pin']}  {name}{store_note}")
        pinned = r.get("pinned")
        cand = r.get("candidate")
        if verdict in ("update", "drift") and pinned and cand:
            note(f"           pinned  v{pinned['versionId']}  "
                 f"{pinned.get('date') or '?'}  "
                 f"{_human_bytes(pinned.get('bytes'))}")
            delta = None
            if cand.get("bytes") is not None and pinned.get("bytes") is not None:
                delta = cand["bytes"] - pinned["bytes"]
            delta_part = ""
            if delta:
                delta_part = (f"  (delta {'+' if delta >= 0 else ''}"
                              f"{_human_bytes(abs(delta))})")
            note(f"           latest  v{cand['versionId']}  "
                 f"{cand.get('date') or '?'}  "
                 f"{_human_bytes(cand.get('bytes'))}"
                 f"{delta_part}")
            measured = "  [measured]" if cand.get("measured") else "  [api-reported]"
            note(f"           sha256  {cand.get('sha')}{measured}")
            model = r.get("model") or {}
            if model.get("url"):
                extra = f" — {model['name']}" if model.get("name") else ""
                note(f"           model   {model['url']}{extra}")
            changelog = cand.get("changelog") or ""
            changelog = " ".join(changelog.split())
            if changelog:
                note("           notes   " + changelog[:140])
        if r.get("note"):
            note(f"           {r['note']}")


def _print_snippets(results, args):
    blocks = [r["snippet"] for r in results if r.get("snippet")]
    if blocks:
        note("# paste-ready entries — same pin ids, drop-in replacements:")
        for r in results:
            if r.get("snippet"):
                note("")
                note(r["snippet"])
    else:
        note("(no snippets: nothing printable)")
    return blocks


def _update_md(path, args, pins, results, targets, tallies, reuse=0, live=0):
    counts = {}
    for r in results:
        counts[r["verdict"]] = counts.get(r["verdict"], 0) + 1
    lines = ["# CivitAI update report", ""]
    lines.append(f"- manifest: `{pins.manifest_path}`")
    civ_n = sum(1 for r in results if r.get("source") == "civitai")
    hf_n = sum(1 for r in results if r.get("source") == "huggingface")
    lines.append(
        f"- scope: {civ_n} civitai pins checked, {hf_n} hf pins checked "
        f"({tallies['other']} other; {len(pins.workflows)} workflow pins "
        f"and {len(pins.legacy)} legacy pins unmanaged here)"
    )
    lines.append(f"- delay: {args.delay}s — generated: {_iso_now()}")
    lines.append(f"- runs: {live} pins checked live, {reuse} reused from "
                 ".lastrun.json (--fresh rechecks)")
    lines += ["", "## summary", ""]
    cats = {}
    for r in results:
        c = r.get("category") or "other"
        d = cats.setdefault(c, {})
        d[r["verdict"]] = d.get(r["verdict"], 0) + 1
    for cat in ("loras", "checkpoints", "embeddings", "other"):
        if cat in cats:
            d = cats[cat]
            lines.append("- " + cat + ": " + ", ".join(
                f"{v} {d[v]}" for v in VERDICTS if d.get(v)))
    tells_n = sum(1 for r in results if r.get("snippet") and r.get("tell"))
    if tells_n:
        lines.append(f"- verify-first: {tells_n} entries carry a verification "
                     "tell; they went to comfyui-updates-verify-first.nix, "
                     "not the category modules")
    for v in VERDICTS:
        if counts.get(v):
            lines.append(f"- {v}: {counts[v]}")
    lines += ["", "| verdict | cat | pin | file | pinned | candidate | note |",
              "|---|---|---|---|---|---|---|"]
    for r in results:
        if r["verdict"] == "up-to-date" and not args.all:
            continue
        pinned = r.get("pinned") or {}
        cand = r.get("candidate") or {}
        lines.append("| {} | {} | {} | {} | {} | {} | {} |".format(
            r["verdict"], r.get("category") or "other", _md_cell(r["pin"]),
            _md_cell(os.path.basename(r["dest"])),
            _md_cell(f"v{pinned.get('versionId')} {pinned.get('date') or ''}"),
            _md_cell(f"v{cand.get('versionId')} {cand.get('date') or ''}"),
            _md_cell(r.get("note") or ""),
        ))
    trows = [r for r in results if r.get("snippet") and r.get("tell")]
    if trows:
        lines += ["", "## verify-first entries (inspect; never blind-paste)", ""]
        for r in trows:
            lines.append(f"- **{r['pin']}** — tell: {r['tell']}")
            if r.get("note"):
                lines.append(f"  - note: {r['note']}")
    blocks = [r["snippet"] for r in results if r.get("snippet")]
    if blocks:
        lines += ["", "## snippets", ""]
        lines.append("```nix")
        for block in blocks:
            lines.append(block)
            lines.append("")
        lines.append("```")
    _atomic_write(path, "\n".join(lines) + "\n")
    progress(args, "md written: " + path)


LM_CLASSES = ("loras", "checkpoints", "embeddings")


def _category_of(pin):
    """LM-style bucket for a pin: loras/checkpoints/embeddings, else other."""
    dest = pin.get("dest") or ""
    parts = dest.split("/")
    if len(parts) > 2 and parts[0] == "models" and parts[1] in LM_CLASSES:
        return parts[1]
    return "other"


def _file_group(category):
    return "lm-parity" if category in LM_CLASSES else "other"


def _lastrun_path(out_dir):
    return os.path.join(out_dir, ".lastrun.json")


def _manifest_digest(path):
    try:
        with open(path, "rb") as f:
            return hashlib.sha256(f.read()).hexdigest()
    except OSError:
        return None


def _load_lastrun(path, manifest_path, args):
    """Stored results from a same-day run over the same manifest, else None."""
    if getattr(args, "fresh", False):
        return None
    try:
        with open(path) as f:
            doc = json.load(f)
    except (OSError, ValueError):
        return None
    if not isinstance(doc, dict):
        return None
    today = datetime.datetime.now(datetime.timezone.utc).date().isoformat()
    if doc.get("day") != today:
        return None
    if doc.get("manifest_sha") != _manifest_digest(manifest_path):
        return None
    stored = doc.get("results")
    return stored if isinstance(stored, dict) else None


def _reusable_result(stored, pin, store):
    """Today's result for this pin when id + versionId + sha256 all match."""
    if not stored:
        return None
    old = stored.get(pin["id"])
    if not isinstance(old, dict) or not isinstance(old.get("verdict"), str):
        return None
    if old["verdict"] == "error":
        return None
    prov = pin.get("provenance") or {}
    old_vid = str((old.get("pinned") or {}).get("versionId") or "")
    if old_vid != str(prov.get("versionId") or ""):
        return None
    sha = (pin.get("sha256") or "").strip().lower()
    if (old.get("local_sha") or "") != sha:
        return None
    old["in_store"] = bool(store["by_digest"].get(sha)) if sha else False
    return old


def _save_lastrun(path, pins, results, stored):
    merged = dict(stored) if stored else {}
    for r in results:
        merged[r["pin"]] = r
    live_ids = {p["id"] for p in pins.models}
    merged = {k: v for k, v in merged.items() if k in live_ids}
    doc = {
        "version": VERSION,
        "manifest": pins.manifest_path,
        "manifest_sha": _manifest_digest(pins.manifest_path),
        "day": datetime.datetime.now(datetime.timezone.utc).date().isoformat(),
        "checked_at": _iso_now(),
        "results": merged,
    }
    _atomic_write(path, json.dumps(doc, indent=1, sort_keys=True) + "\n")


def _write_nix_module(path, header, rows, with_tells=False):
    text = (header + "{ lib, hfFetch, civitaiFetch }:\n\n{\n")
    cur_cat = None
    for r in rows:
        cat = r.get("category") or "other"
        if cat != cur_cat:
            cur_cat = cat
            text = text + "\n      # --- " + cat + " ---\n"
        part = r["snippet"]
        marks = []
        if r.get("source") == "huggingface":
            marks.append("was an hfFetch pin — this candidate adopts civitai "
                         "provenance")
        if with_tells:
            marks += ["tell: " + t
                      for t in str(r.get("tell") or "").split("; ")]
        if marks:
            part = "\n".join("      # " + m for m in marks) + "\n" + part
        text = text + "\n" + part + "\n"
    text = text + "\n}\n"
    with open(path, "w") as f:
        f.write(text)


def _models_map_path(out_dir):
    return os.path.join(out_dir, ".models-map.json")


def _load_models_map(path):
    try:
        with open(path) as f:
            doc = json.load(f)
    except (OSError, ValueError):
        return {}
    return doc if isinstance(doc, dict) else {}


def _save_models_map(path, models_map):
    if models_map:
        _atomic_write(path,
                      json.dumps(models_map, indent=1, sort_keys=True) + "\n")


def _write_updates_files(out_dir, results, args, pins, targets, tallies,
                         reuse_n, live_n):
    os.makedirs(out_dir, exist_ok=True)
    clean = [r for r in results if r.get("snippet") and not r.get("tell")]
    tells = [r for r in results if r.get("snippet") and r.get("tell")]
    written = []
    groups = {"lm-parity": [], "other": []}
    for r in sorted(clean, key=lambda r: (r.get("category") or "other",
                                          r["pin"])):
        groups[_file_group(r.get("category") or "other")].append(r)
    group_headers = {
        "lm-parity":
            ("# Lora-Manager-parity updates: the loras / checkpoints /\n"
             "# embeddings entries LM's update view covers. Clean candidates\n"
             "# only (no verification tells). Paste into the matching\n"
             "# downloads/<family>.nix files.\n"),
        "other":
            ("# Updates on pins OUTSIDE Lora Manager's index: diffusion\n"
             "# models, text encoders, vaes, upscalers, adapters, tooling.\n"
             "# Clean candidates only. Safe to paste.\n"),
    }
    for gname in ("lm-parity", "other"):
        rows = groups[gname]
        if not rows:
            continue
        path = os.path.join(out_dir, "comfyui-updates-" + gname + ".nix")
        _write_nix_module(path, group_headers[gname], rows)
        written.append((os.path.basename(path), len(rows)))
    if tells:
        path = os.path.join(out_dir, "comfyui-updates-verify-first.nix")
        header = ("# NOT auto-safe — every entry below carries a verification\n"
                  "# tell: a candidate shared by several store pins (only one\n"
                  "# can be the real bump) or a non-primary hf file inside a\n"
                  "# multi-file civitai version. Read the tells + report.\n")
        _write_nix_module(path, header, sorted(tells, key=lambda r: (
            r.get("category") or "other", r["pin"])), with_tells=True)
        written.append((os.path.basename(path), len(tells)))
    md_path = args.md or os.path.join(out_dir, "comfyui-updates.md")
    _update_md(md_path, args, pins, results, targets, tallies,
               reuse=reuse_n, live=live_n)
    written.append((os.path.basename(md_path), len(results)))
    return written


def _hf_clean_in_group(clean, results, gname):
    clean_by_id = {r["pin"] for r in clean}
    return sum(1 for r in results if r["pin"] in clean_by_id and r.get("source") == "huggingface" and _file_group(r.get("category") or "other") == gname)


def _console_files_line(written, args):
    print("written to " + (args.out_dir or ".") + ": " + ", ".join(
        name + (f" ({n} entries)" if n else "")
        for name, n in written))


def _console_summary(args, results, counts, written, reuse_n, live_n):
    print(f"civitai update check: {len(results)} pins "
          f"({reuse_n} reused from .lastrun, {live_n} checked live)")
    print("verdicts: " + ", ".join(
        f"{v} {counts[v]}" for v in VERDICTS if counts.get(v)))
    buckets = {}
    clean = [r for r in results if r.get("snippet") and not r.get("tell")]
    for r in results:
        if r.get("verdict") not in ("update", "drift"):
            continue
        cat = r.get("category") or "other"
        b = buckets.setdefault(_file_group(cat), {})
        b.setdefault(cat, {"clean": 0, "tell": 0})
        b[cat]["tell" if r.get("tell") else "clean"] += 1
    for gname in ("lm-parity", "other"):
        b = buckets.get(gname)
        if not b:
            continue
        label = ("lm-parity (loras/checkpoints/embeddings)"
                 if gname == "lm-parity" else "other (outside lm's index)")
        chunks = []
        for cat, d in sorted(b.items()):
            if gname == "other" and cat == "other":
                chunks.append("{} clean, {} verify-first".format(
                    d["clean"], d["tell"]))
            else:
                chunks.append("{}: {} clean, {} verify-first".format(
                    cat, d["clean"], d["tell"]))
        line = f"{label} → {gname}: " + "; ".join(chunks)
        hf_g = _hf_clean_in_group(clean, results, gname)
        if hf_g:
            line = line + " ({} from hf pins)".format(hf_g)
        print(line)
    tell_rows = [r for r in results if r.get("snippet") and r.get("tell")]
    if tell_rows:
        print(f"verify-first: {len(tell_rows)} entries in "
              "comfyui-updates-verify-first.nix:")
        for r in tell_rows:
            first = (r.get("note") or r["tell"])[:100]
            print(f"  {r['pin']}: {first}")
    if written:
        _console_files_line(written, args)
    errs = counts.get("error", 0)
    if errs:
        print(f"warning: {errs} error verdict(s) — detail in the report; "
              "exit status is 1")


def cmd_updates(args):
    pins = PinStore(args.manifest, args.dataDir)
    store = pins.scan_store()
    targets, tallies = _resolve_targets(pins, args.only)
    out_dir = os.path.abspath(args.out_dir or ".")
    lastrun_path = _lastrun_path(out_dir)
    stored = _load_lastrun(lastrun_path, pins.manifest_path, args)
    cache_path = None
    if not args.no_cache:
        cache_path = args.cache or _default_cache_path()
    if cache_path is None:
        cache_path = ""
    api = Civitai(delay=args.delay, mirror=args.mirror,
                  cache_path=cache_path or None, cache_ttl_h=args.cache_ttl)

    def _is_hf(p):
        return (p.get("provenance") or {}).get("source") == "huggingface"
    hf_total = sum(1 for p in pins.models if _is_hf(p))
    hf_part = ", +{} hf by-hash".format(hf_total) if args.include_hf else ""
    progress(args, "api: {} civitai pins{}, delay {}s, mirror {}, cache {}".format(
        len(targets), hf_part, args.delay, args.mirror or "off",
        cache_path or "off"))
    if stored is not None:
        progress(args, f"lastrun: reusing same-day results from "
                 f"{lastrun_path} (--fresh to recheck)")
    models_map = {}
    models_map_path = None
    if not args.no_files:
        models_map_path = _models_map_path(out_dir)
        models_map = _load_models_map(models_map_path)
        for p in pins.models:
            prov = p.get("provenance") or {}
            if prov.get("source") == "civitai" and prov.get("modelId"):
                vid_key = str(prov.get("versionId") or "")
                mid_seed = _parse_int(prov.get("modelId"))
                if vid_key and mid_seed:
                    models_map[vid_key] = mid_seed
    token_cache = {}
    pinned_by_vid = {}
    for p in pins.models:
        raw_pv = (p.get("provenance") or {}).get("versionId")
        pv = _parse_int(raw_pv) if raw_pv is not None else None
        if pv:
            pinned_by_vid.setdefault(pv, []).append(str(p.get("id")))
    results = []
    reuse_n = 0
    live_n = 0

    def run_check(pin, checker, token_override=None):
        """Reuse today's stored verdict when unchanged, else check live."""
        old = _reusable_result(stored, pin, store)
        if old is not None:
            results.append(old)
            return True
        token = _token_arg(pin, args, token_cache)
        if token_override is not None:
            token = token_override
        try:
            results.append(checker(pin, token))
        except Exception as e:
            row = _blank_result(pin, store)
            row["verdict"] = "error"
            row["note"] = "unexpected: " + repr(e)
            results.append(row)
        return False

    for pin in sorted(targets, key=lambda p: str(p.get("id", ""))):
        reused = run_check(
            pin, lambda p, tk: _check_civitai_pin(
                api, p, tk, store, args, pinned_by_vid, models_map))
        reuse_n += 1 if reused else 0
        live_n += 0 if reused else 1
        results[-1]["category"] = _category_of(pin)
        note_part = (f" — {results[-1].get('note')}"
                     if results[-1].get("note") else "")
        progress(args, f"{results[-1]['verdict']:10} {pin['id']}{note_part}")
    if args.include_hf:
        civ_token_path = None
        for p in pins.models:
            if (p.get("provenance") or {}).get("source") == "civitai":
                civ_token_path = p.get("tokenFile")
                break
        hf_targets = []
        for p in pins.models:
            if _is_hf(p) and (not args.only or args.only.lower() in str(p.get("id", "")).lower()):
                hf_targets.append(p)
        resolved = None
        hf_shas = [str(p.get("sha256") or "").strip().lower()
                   for p in hf_targets]
        if any(hf_shas):
            resolved = {"hits": {}, "misses": set()}
            hf_token = _read_token(args.token_file or civ_token_path,
                                   token_cache)
            for start in range(0, len(hf_shas), 100):
                chunk = [s for s in hf_shas[start:start + 100] if s]
                if not chunk:
                    continue
                try:
                    docs = api.post(
                        CIVITAI_BASE + "/api/v1/model-versions/by-hash",
                        hf_token, chunk)
                except (ApiError, NotFound, Transient) as e:
                    progress(args, "by-hash batch failed (" + str(e) + ") — per-pin fallback")
                    continue
                digests = []
                for doc in (docs if isinstance(docs, list) else []):
                    own = set()
                    for f in (doc.get("files") or []):
                        h = (f.get("hashes") or {}).get("SHA256")
                        if h:
                            own.add(str(h).lower())
                    digests.append((doc, own))
                for sha in chunk:
                    match = next((doc for doc, own in digests if sha in own),
                                 None)
                    if match is not None:
                        resolved["hits"][sha] = match
                    else:
                        resolved["misses"].add(sha)
            progress(args, "by-hash batches: {}/{} of {} shas resolved".format(
                len(resolved["hits"]), len(hf_shas),
                len(hf_shas) - hf_shas.count("")))
        for p in hf_targets:
            # by-hash + model GETs are civitai api calls: they carry the
            # CIVITAI token (mirror-first + masking follow). The pin's own
            # hf token only drives the HEAD probe fallback.
            civ_token = _read_token(args.token_file or civ_token_path,
                                    token_cache)
            reused = run_check(
                p, lambda pp, tk: _check_hf_pin(
                    api, pp, tk, store, args, pinned_by_vid, resolved),
                token_override=civ_token)
            reuse_n += 1 if reused else 0
            live_n += 0 if reused else 1
            results[-1]["category"] = _category_of(p)
            note_part = (f" — {results[-1].get('note')}"
                         if results[-1].get("note") else "")
            progress(args, f"{results[-1]['verdict']:10} {p['id']}{note_part}")
    shared_cand = {}
    for r in results:
        if r.get("verdict") == "update" and (r.get("model") or {}).get("id"):
            shared_cand.setdefault(
                ((r.get("model") or {}).get("id"),
                 str((r.get("candidate") or {}).get("versionId"))), []).append(r)
    for rows in shared_cand.values():
        if len(rows) > 1:
            for r in rows:
                shared = "same candidate shared by {} store pins".format(
                    len(rows))
                extra = shared + " — verify the variant before applying"
                r["note"] = (r.get("note") + "; " + extra
                             if r.get("note") else extra)
                r["tell"] = "; ".join(
                    x for x in (r.get("tell"), shared) if x)
    api.flush()
    if models_map_path is not None:
        _save_models_map(models_map_path, models_map)
    progress(args, "api: {} live calls, {} cache hits; model map: {} version ids".format(
        api.fetches, api.hits, len(models_map)))
    counts = {}
    for r in results:
        counts[r["verdict"]] = counts.get(r["verdict"], 0) + 1
    written = None
    if not args.no_files:
        written = _write_updates_files(out_dir, results, args, pins,
                                       targets, tallies, reuse_n, live_n)
        _save_lastrun(lastrun_path, pins, results, stored)
    if args.json:
        payload = {
            "version": VERSION,
            "generated_at": _iso_now(),
            "manifest": pins.manifest_path,
            "delay_s": args.delay,
            "reused": reuse_n,
            "checked_live": live_n,
            "summary": {v: counts[v] for v in VERDICTS if counts.get(v)},
            "pins": results,
            "files": [w[0] for w in (written or [])],
            "snippets": [r["snippet"] for r in results if r.get("snippet")],
        }
        print(json.dumps(payload, indent=1, sort_keys=True))
        return _updates_rc(results)
    if args.print_snippets or args.nix_snippets:
        _print_updates(results, args)
        note("")
        _print_snippets(results, args)
        if written:
            _console_files_line(written, args)
        return _updates_rc(results)
    _console_summary(args, results, counts, written or [], reuse_n, live_n)
    return _updates_rc(results)


def _token_arg(pin, args, cache):
    if args.token_file:
        return _read_token(args.token_file, cache)
    return _read_token(pin.get("tokenFile"), cache)


def _updates_rc(results):
    for r in results:
        if r["verdict"] == "error":
            return 1
    return 0


class _HelpFmt(argparse.ArgumentDefaultsHelpFormatter,
               argparse.RawDescriptionHelpFormatter):
    """Show flag defaults AND keep epilog/paragraph formatting."""


EPILOG_MAIN = """subcommands:
  report   classify local pin-store/model-tree state (no network access)
  updates  additionally check civitai for newer versions of pinned models

examples:
  comfyui-report report                     local classification
  comfyui-report report --filter problems   only classes needing action
  comfyui-report updates --nix-snippets     review + paste-ready entries
  comfyui-report updates --only col_xl --verify   verify one pin's bytes

run 'comfyui-report <sub> --help' for a subcommand's full flag list."""

EPILOG_REPORT = """classes (current = healthy; the rest are notes or tasks):
  current           blob + correct symlink at the pin's dest
  adoptable         real file at the dest, hashing to the pin's sha256
  impostor          real file at the dest, hashing to something else
  real-file         real file at the dest, not hashed (--no-hash)
  link-drift        next boot repairs the link without a download
  fetch-pending     bytes exist nowhere local; the boot pass will fetch
  legacy            legacy real-file pins (unzipInto / non-models dest)
  legacy-mismatch   legacy real-file pin whose dest bytes diverge
  workflow          workflow pins under the read-only nix-managed namespace
  update-orphan     orphan blob superseded by a newer version of its pin
  unpinned-orphan   orphan blob with no provable lineage
  dedup             blobs sharing one digest (one content, several names)
  companion         sidecar companion of a present model (metadata, image)
  companion-orphan  a companion whose model file has vanished
  stray             entries under models/** claimed by no pin
  rot               unexpected entries at the store root

exit status: 0 when nothing needs attention, else 1."""

EPILOG_UPDATES = """verdicts per civitai pin:
  up-to-date   pinned versionId is the newest version on its baseModel
               (model-wide latest with --model-wide-latest); when the
               family's newest same-base version is itself pinned here, a
               note names that sibling pin
  update       a newer version on the same baseModel exists; sha256 of
               its primary file reported
  drift        same versionId re-uploaded upstream; hash changed
  deleted      pinned version no longer in the model's version list
  not_found    version (or model) answers 403/404 on civitai.com and mirror
  error        transport failure after retries

--include-hf (default on): huggingface pins resolve identity via the
by-hash index and run the same logic; hf-sourced candidates are marked
in every generated module. "not on civitai by hash" notes up-to-date.
newer versions on other base models are notes, not verdict changes.

newer versions on other base models are notes, not verdict changes.

files: comfyui-updates.md + comfyui-updates-<category>.nix per category
(categories: loras, checkpoints, embeddings, other) with CLEAN entries
only, plus comfyui-updates-verify-first.nix for entries carrying a
shared-candidate / non-primary tell — inspect those, never blind-paste.
.lastrun.json short-circuits same-day reruns; --fresh rechecks all.

api calls: paced (--delay) against the civitai API only; `report` and the
local scans never touch the network. exit status: 0, else 1 on any error."""


def build_argparser():
    parser = argparse.ArgumentParser(
        prog="comfyui-report",
        description="read-only pin-store reporting and civitai update checks",
        epilog=EPILOG_MAIN,
        formatter_class=_HelpFmt,
    )
    parser.add_argument("--version", action="version",
                        version=f"comfyui-report ({VERSION})")
    sub = parser.add_subparsers(dest="mode", required=True)

    def common(sp):
        sp.add_argument("--manifest", default=DEFAULT_MANIFEST or None,
                        help="pin manifest json (default: baked at build)")
        sp.add_argument("--dataDir", default=DEFAULT_DATA_DIR or None,
                        help="comfyui data directory (default: baked at build)")
        sp.add_argument("--only", default="",
                        help="restrict to pin ids containing this substring")

    report_p = sub.add_parser(
        "report", help="classify local state (no network)",
        description="classify local pin-store and models-tree state "
        "against the manifest; no network access",
        epilog=EPILOG_REPORT, formatter_class=_HelpFmt)
    common(report_p)
    report_p.add_argument(
        "--filter", action="append", default=None, metavar="CLASS",
        help="class(es) to detail, comma separated; keywords: all, problems; "
        f"default: {DEFAULT_FILTER_CLASSES}")
    report_p.add_argument("--json", action="store_true",
                          help="emit the full report as json on stdout")
    report_p.add_argument("--md", metavar="PATH", default=None,
                          help="also write a markdown snapshot to PATH")
    report_p.add_argument(
        "--no-hash", action="store_true", help="skip hashing real files at "
        "pin dests (they land in real-file instead of adoptable/impostor)")

    updates_p = sub.add_parser(
        "updates", help="check civitai for newer versions of pinned models",
        description="check every civitai-sourced pin against the civitai "
        "API and classify up-to-date/update/drift/deleted",
        epilog=EPILOG_UPDATES, formatter_class=_HelpFmt)
    common(updates_p)
    updates_p.add_argument("--token-file", default=None,
                           help="bearer token override; default: each pin's "
                           "own tokenFile from the manifest")
    updates_p.add_argument("--delay", type=float, default=2.0,
                           help="seconds between api requests")
    updates_p.add_argument("--mirror", default=MIRROR_DEFAULT,
                           help="mirror host used on 403/404 — tried first "
                           "when a token rides the request; '' disables")
    updates_p.add_argument("--no-cache", action="store_true",
                           help="bypass the api response cache entirely")
    updates_p.add_argument("--cache", default=None, metavar="PATH",
                           help="cache file location; default "
                           "$XDG_CACHE_HOME/comfyui-report/civitai-cache.json")
    updates_p.add_argument("--cache-ttl", type=float, default=24.0,
                           metavar="HOURS", help="cache entry max age")
    updates_p.add_argument("--out-dir", default=".", metavar="DIR",
                           help="where the report + per-category nix modules "
                           "are written (default: current directory)")
    updates_p.add_argument("--fresh", action="store_true",
                           help="ignore today's .lastrun.json and recheck "
                           "every pin (the api cache still applies)")
    updates_p.add_argument("--no-files", action="store_true",
                           help="stdout only — write no report/module/lastrun "
                           "files")
    updates_p.add_argument(
        "--model-wide-latest", action="store_true",
        help="compare against the model's overall latest version instead of "
        "same-baseModel versions (variant families then read sibling "
        "versions as updates)")
    updates_p.add_argument(
        "--include-hf", action=argparse.BooleanOptionalAction, default=True,
        help="check huggingface pins too (default on): identity via civitai "
        "by-hash (the pinned sha256), same update logic; --no-include-hf to "
        "skip; without a pin sha256, HEAD probe (advisory)")
    updates_p.add_argument("--print-snippets", action="store_true",
                           help="print the full per-pin listing + paste-ready "
                           "entries to stdout (files are still written "
                           "unless --no-files)")
    updates_p.add_argument("--nix-snippets", action="store_true",
                           help="deprecated alias of --print-snippets")
    updates_p.add_argument(
        "--follow-upstream-names", action="store_true",
        help="snippets take the candidate's upstream filename; the default "
        "keeps the existing local dest name (stable-name policy)")
    updates_p.add_argument(
        "--verify", action="store_true",
        help="download + hash each candidate before printing its snippet")
    updates_p.add_argument("--verify-dir", default=None, metavar="PATH",
                           help="where --verify stages bytes (default tmp)")
    updates_p.add_argument(
        "--keep-verified", action="store_true",
        help="retain verified download bytes instead of deleting them")
    updates_p.add_argument(
        "--all", action="store_true", help="also list up-to-date pins")
    updates_p.add_argument("--json", action="store_true",
                           help="emit the full result as json on stdout")
    updates_p.add_argument("--md", metavar="PATH", default=None,
                           help="also write a markdown report to PATH")
    return parser


def main(argv=None):
    args = build_argparser().parse_args(argv)
    if args.mode == "report":
        return cmd_report(args)
    return cmd_updates(args)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BrokenPipeError:
        # Piping into head/less is normal for a report tool; exit quietly
        # instead of tracebacking on the flush of a closed stdout.
        os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
        sys.exit(141)
