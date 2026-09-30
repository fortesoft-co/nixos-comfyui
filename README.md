# ComfyUI NixOS module

A declarative ComfyUI stack wrapping the native NixOS module from
[github:utensils/comfyui-nix](https://github.com/utensils/comfyui-nix): the
service, its data layout, a content-addressed model store, opt-in custom node
packs, declarative workflows, and MCP tooling — all pinned, no runtime pip
installs, no host assumptions baked into the module.

## Layout

| File | Role |
|---|---|
| `default.nix` | Orchestration module: wires the cfg.comfyui interface onto `services.comfyui`, imports everything below. The only entry point. |
| `modules/options.nix` | `cfg.comfyui.*` options (generic defaults — this folder ships as a module) |
| `modules/sources.nix` | Fetch-entry constructors: `hfFetch` (HF repo+rev+file) and `civitaiFetch` (civitai versionId), each injecting the right token |
| `modules/downloads.nix` | Pin-store units (`pin-plan`/`pin-seal`/`pin-audit`) around `tools/download_runtime.py`: content-addressed `dataDir/store`, boot relink/fetch pass, root placement, audit timer |
| `modules/nodes.nix` | Opt-in custom node packs (see below), merged into `services.comfyui.customNodes` |
| `modules/workflows.nix` | Declarative workflow installation (`workflows` attrset + `workflowDirs` directory mapping) |
| `modules/mcp.nix` | Comfy Org's MCP server + comfy-cli on `mcpUsers`' PATH |
| `tools/workflow_api_to_ui.py` | Authoring-time converter: API-format workflow JSON → UI-format (needs the running server's `object_info`) |

## Quick start

```nix
# consumer flake.nix
inputs.comfyui-nix.url = "github:utensils/comfyui-nix";
inputs.nixos-comfyui.url = "github:<owner>/nixos-comfyui";

# pass both into the module: specialArgs = { comfyui-nix = ...; nixos-comfyui = ...; };

# configuration module
imports = [ nixos-comfyui.nixosModules.default ];
cfg.comfyui = {
  dataDir = "/mnt/data/comfyui";         # models/user/custom_nodes/input/output
  gpuSupport = "cuda";                   # cuda | rocm | xpu | none
  group = "media";                       # primary group of the service user
  openFirewall = true;
  port = 8188;
  enableCivitaiNodes = true;
  enableLoraManager = true;
  enableCrystools = true;
  downloads = {
    "some-model" = civitaiFetch {
      type = "checkpoints";
      name = "some-model.safetensors";
      versionId = "123456";
      sha256 = "...";
    };
    "some-lora" = hfFetch {
      type = "loras";
      repo = "some/repo";
      rev = "<commit sha>";
      file = "some-lora.safetensors";
      sha256 = "...";
    };
  };
  workflowDirs = [ ./workflows ];        # UI-format graphs, whole tree mapped
  mcpUsers = [ "myuser" ];
};
```

This flake exposes `nixosModules.default` (see `flake.nix`); consumers may
also import `./default.nix` directly and pass `comfyui-nix` via
`specialArgs`. Everything machine-specific (dataDir paths, mounts, firewall,
user enablement) belongs in the consumer, not in this repository.

## Consuming locally

During development the consumer flake can point at this checkout by path:

```nix
# consumer flake.nix
inputs.nixos-comfyui.url = "path:/path/to/nixos-comfyui";
```

Path inputs are locked by content hash — after editing files here, relock
before the next rebuild or the stale store copy is used:

```console
nix flake lock --update-input nixos-comfyui
```

When this repository is published, the same input becomes a
`github:<owner>/<repo>` URL and the rest is unchanged.

## Options (cfg.comfyui.*)

| Option | Default | Purpose |
|---|---|---|
| `dataDir` | `/var/lib/comfyui` | Models, user dir, custom_nodes, input, output |
| `user` / `group` | `comfyui` | Dedicated unprivileged service account (created by the upstream module) |
| `gpuSupport` | `none` | `cuda` / `rocm` / `xpu` / `none` |
| `port` | `8188` | HTTP port the MCP tooling also targets |
| `openFirewall` | `false` | LAN access |
| `requiresMounts` | `[]` | Mount units gating the service + fetcher (nofail mounts) |
| `mcpUsers` | `[]` | Users getting comfy-mcp / comfy-cli on PATH |
| `enableCivitaiNodes` | `false` | Official Civitai pack (in-graph downloads) |
| `enableLoraManager` | `false` | LoRA Manager model-library UI at `/loras` |
| `enableCrystools` | `false` | GPU/RAM monitors + utility nodes |
| `civitaiApiKeyFile` / `huggingfaceTokenFile` | `null` | Paths to token files (any mechanism — e.g. agenix-decrypted secrets), wired to the fetcher + service env |
| `downloads` | `{}` | Declarative pins (id-keyed; see Downloads) |
| `workflowsDir` | `user/default/workflows` | Install root for declarative workflows |
| `workflows` | `{}` | Explicit workflow files (`dataDir path → store path`) |
| `workflowDirs` | `[]` | Directories mapped wholesale under `workflowsDir` |

## Downloads

Pins live in the consumer's host file. Two destination styles per entry:

- **structured** (`type`/`arch`/`name`, or an explicit `dataDir`-relative
  `dest` under `models/`) — the bytes land in a root-owned,
  content-addressed store (`dataDir/store/<stem>--<sha256><ext>`, mode
  0444) and the `models/**` entry is an absolute symlink into it;
- **real-file** (`dest` entries outside `models/`, and `unzipInto`
  bundles) — fetched straight to the destination, ZIPs extracted into a
  checksummed tree that is re-verified on each pass.

`modules/sources.nix` builds pinned URLs and injects the right token per
source (fetched with resumable curl):

- `hfFetch { repo, rev, file, sha256 }` — HuggingFace resolve URL pinned to
  a commit SHA; the HF token covers gated repos and is harmless elsewhere.
- `civitaiFetch { versionId, sha256 }` — the model-version download
  endpoint; the key is a bearer token on the initial request only (the CDN
  redirect is signed).
- Plain `{ url, sha256 }` attrsets work for arbitrary hosts.

Semantics: existing files are **never overwritten** (the seal is the only
placement, and it parks a drifted file in quarantine instead of destroying
it), downloads resume, every pin is sha256-gated, `fallbackUrls` keep
entries alive when upstream disappears, `unzipInto` extracts ZIP packs.
Three systemd units do the work: `comfyui-pin-plan` (boot pass as the
service user — relink, fetch, promote), `comfyui-pin-seal` (root oneshot —
measures, places, owns, links) and `comfyui-pin-audit` (OnCalendar timer,
via `auditSchedule` — full store sweep + orphan report). Re-run the boot
pass mid-session with `sudo systemctl start comfyui-pin-plan`.

## Workflows

Two mechanisms, one split:

- **`downloads`** for *remote* workflow files (pinned URL + sha256) — e.g.
  official example workflows from a model repo.
- **`workflows` / `workflowDirs`** for *locally authored* graphs kept in the
  repository. `workflowDirs` maps a whole directory tree under
  `workflowsDir` preserving subfolders.

Files must be **UI-format** (nodes/links) — the frontend browser only
renders those. Author new workflows in API format, then convert:

```console
python3 tools/workflow_api_to_ui.py my-graph.api.json my-graph.json
comfy workflow validate --workflow my-graph.json
```

The converter is schema-driven from the running server's `/object_info`, so
it is an authoring-time step (tooling-side), not a build-time one.

Deployment is conflict-safe: a deployed workflow that is byte-identical to
the repo version is left alone; one that diverges (edited in the UI) is
moved aside to `<name>_<timestamp>.json` and the repo version installed —
local edits are preserved, never clobbered.

## Model fetch + node packs

Model lists live in the consumer (host file) and use the constructors above.
Node packs are opt-in options in `modules/nodes.nix` — each is a
`fetchFromGitHub`-pinned entry behind an `enable*` flag; the upstream flake
bundles a further set (Impact Pack, KJNodes, ComfyUI-GGUF, rgthree,
LTXVideo, Florence2, x-flux, MMAudio, PuLID, WanVideoWrapper, ...) symlinked
at service start. Do not declare a customNodes entry under a bundled name.

`customNodes` is an attrset, so consumer entries merge with the module's.

## MCP tooling

`modules/mcp.nix` packages Comfy Org's MCP server + comfy-cli into a standalone
interpreter env for `mcpUsers`. It drives the running service over HTTP —
see `AGENTS.md` for the tooling rules (lifecycle stays with systemd).

## Maintenance

- Bump a node pack: update `rev` + `hash` together (`nix flake prefetch
  github:<owner>/<repo>` prints the hash).
- New downloads: `git add` new files before evaluating (flakes only see
  tracked files).
- Removed `downloads` entries leave their content in place (a store blob
  without a pin becomes an audit-reported orphan, never deleted); replacing
  a pin's bytes requires deleting the store blob (root) first — placement
  never overwrites.