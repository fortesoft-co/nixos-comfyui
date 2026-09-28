# AGENTS.md

Rules and instructions for agents and humans contributing to this
repository: a standalone NixOS module for declaratively deploying
ComfyUI — service wiring, opt-in node packs, a hash-pinned download
fetcher, declarative workflow installation, and MCP tooling.

## Content rules (hard — apply to every commit)

- **Content-free by policy.** No model pins, model names, workflow
  graphs, or any consumer content lives here: host values (paths,
  mounts, users) and all model/workflow content belong to the consumer
  repo that imports this module.
- **No NSFW-related content may be authored or committed** — not in
  code, string literals, names, examples, docs, or commit messages.
  When in doubt, use innocuous language.
- The repo's history is part of the repo: every rule above applies to
  commit messages too.

## Scratchpad

`.scratch/` (gitignored) is the local scratchpad: live-verification
artifacts, throwaway scripts, working notes. Local-only — never commit
it, never reference it from tracked files.

## Module map

```
default.nix            entry point; wires cfg.comfyui onto services.comfyui
modules/options.nix    cfg.comfyui.* interface (shippable defaults)
modules/sources.nix    hfFetch / civitaiFetch URL+token constructors
modules/downloads.nix  comfyui-download-fetch oneshot (no-clobber, resumable)
modules/nodes.nix      opt-in node packs (enable* flags)
modules/workflows.nix  declarative workflow installation
modules/mcp.nix        comfy-mcp + comfy-cli for mcpUsers
tools/
workflow_api_to_ui.py  API-format -> UI-format workflow converter (authoring-time)
```

An inverse converter (UI-format -> API-format, schema-driven from the live
server) is useful for loading a saved workflow, mutating it
programmatically (swap models, append stages) and re-saving — it lives with
the operator's authoring tooling, not in this repository. Watch for node-id
collisions when appending: saved graphs reuse ids up to ~100, so appended
stages start at 200.

Host assumptions never live in this repository — machine values (paths,
mounts, users) go in the consumer, which imports this module and passes
`comfyui-nix` via `specialArgs`.

## Golden rules

1. **systemd owns the service.** Never use comfy-cli lifecycle tools
   (`launch_comfyui`/`stop_comfyui`/`restart_comfyui`) — they assume they own
   a ComfyUI checkout and will fight the service. `sudo systemctl restart
   comfyui` is the only restart. The MCP HTTP tools (run_workflow, job,
   fetch_outputs, ...) are fine: they are pure API clients.
2. **The flake only sees tracked files.** After creating any file the eval
   must see: `git add` it first, or evaluation fails with "not tracked by
   Git" (the error names the file).
3. **The service user owns dataDir.** Agents running in editors land as an
   unprivileged user; reading staged files is fine, writing into
   `models/`, `user/`, `output/` is not. Two clean paths: the ComfyUI HTTP
   API (uploads go through `/upload`, workflows through the userdata API —
   both run as the service user), or a user-supplied sudo command. Never
   `rm` service files; the no-clobber fetcher + UI tooling are the writers.
4. **Flakes + new files**: after adding anything under a directory the eval
   reads (workflows dir, module files), `git add` before the next
   `nix eval`/rebuild.
5. **Conflict-safe everywhere**: the fetcher never touches existing files;
   the workflow installer goes further — if a deployed workflow differs from
   the repo version, the local copy is moved aside to `<name>_<timestamp>.json`
   and the repo version installed. Local edits are never lost, either way.
6. **Keep host values in the host file.** This folder must stay shippable as
   a standalone module: paths, group, mounts, enable flags belong in the
   consumer.

## ComfyUI HTTP API — the working patterns

- **Schema discovery**: `GET /object_info/<NodeType>` — the single source of
  truth for a node's inputs (types, defaults, `input_order`), outputs and
  enums. Always generate graphs against it; never hand-remember widget
  orders.
- **Submit**: `POST /prompt` with `{"prompt": <API-format graph>,
  "client_id": ...}`. Returns `prompt_id` immediately; HTTP 400 carries
  per-node validation errors in `node_errors` — read them, they name the
  node and the exact type mismatch.
- **Poll**: `GET /history/<prompt_id>` — empty until finished; then
  `status.status_str` is `success`/`error` and `outputs` carries image
  locations. `execution_error` messages include the failing node.
- **Queue management**: `POST /queue` with `{"delete": [<prompt_id>...]}`.
- **Images**: SaveImage writes under `dataDir/output/<subfolder>`; poll
  history for exact filenames.
- **Reference images**: stage via `POST /upload` (multipart) into `input/`,
  referenced by bare filename in LoadImage.

### userdata API quirks (saving workflows server-side)

- Writes are `POST /userdata/<path>?overwrite=true` with raw body. The path
  parameter is **single-segment only** — a subdirectory must be percent-
  encoded as one segment: `/userdata/workflows%2Fedit%2Ffoo.json`. A literal
  `workflows/foo.json` path 405s.
- Only root-level `GET`/`DELETE` worked without the encoding trick too —
  always encode subpaths as `%2F`, and use `?full_info=true` on writes to see
  where a file actually landed.
- Files written this way are mode 600, service-user owned. The frontend
  reads them over HTTP fine; for direct file access `sudo chmod a+r` after.

## Workflow authoring loop

1. Build the **API-format graph** as JSON: node ids are strings, each node is
   `{"class_type": ..., "inputs": {...}}`; connections are `["<node_id>",
   <output_slot>]`.
2. Convert: `python3 tools/workflow_api_to_ui.py graph.json graph.ui.json`
   (schema-driven: widget ordering, `control_after_generate` states,
   converted-widget sockets, optional-socket elision).
3. Validate: `comfy workflow validate --workflow graph.ui.json` — this
   round-trips UI→API and checks every node against the live server.
4. Deploy: POST to `/userdata/workflows%2F<subdir>%2F<name>.json`.
5. Persist into the consumer's workflow directory (e.g. `<workflows>/<name>.json`), `git add`
   — the `workflowDirs` mapping installs it declaratively on next rebuild
   (no-clobber: delete the deployed copy first if it changed).

The converter handles: widget ordering from `input_order`, seed
`control_after_generate` (appends the control string), GetImageSize-style
INT links that are converted widgets (socket + retained widget value),
optional-socket elision, and COMBO declarations whose "type" is a list of
options. Watch for dual-nature types: `STRING` is both a widget input and a
node output type — genuine STRING sockets always declare `forceInput`.

## Downloads discipline

- Pin **rev + sha256** always. HF: the tree API's `lfs.oid` is the sha256
  (non-LFS small files have none — download and hash locally). Civitai's API
  reports hashes UPPERCASE — lowercase them for pins.
- The civitai API (`/api/v1/models/<id>`) is public for metadata; **civitai.red**
  is the site's mirror (API on the same domain) — use it when a model is
  invisible on the filtered site. Some articles are Cloudflare-gated
  to non-browser agents. Gated HF repos mask hashes to anonymous callers —
  if a tree returns masked oids, find a mirror (search HF for the filename)
  and verify byte-identity via sha256 before pinning either.
- Empty-file red flag: a sha256 of `e3b0c44...` means a 0-byte file — never
  pin that; investigate the source.
- Stage the *support* models too, not just the headline ones: swap/pose
  tools bring their own detection models and runtime dependencies. Before
  adding python packages, check the runtime env's `site-packages` first —
  the upstream flake already ships more than you'd guess. When a repo ships
  example workflows, stage them via the downloads option (pinned) — they
  document intended wiring (sampler, guidance, schedulers) better than
  memory.

## Fetch service ops

`comfyui-download-fetch.service` runs at boot (and on activation) only. If
entries were added since the last boot: `sudo systemctl start
comfyui-download-fetch`. It resumes partial downloads, verifies hashes, and
**fails as a unit** if any entry cannot be satisfied — a bad pin blocks all
downstream fetches, so verify hashes before pinning and use `fallbackUrls`
for fragile sources.

## Testing loop conventions

- Test graphs go to `output/test/<NN>_<name>_00001_.png` via
  `filename_prefix: "test/<name>"` — numbered prefixes keep rounds sortable.
- Submit all variants in one batch (the server serialises them on the GPU),
  then poll `/history` for each.
- Same seed + same prompt with one changed knob = clean A/B; log verdicts
  (keep/save/park) per test.

## Service ops

- `sudo systemctl restart comfyui` — the only lifecycle.
- Logs: `comfyui_8188.log` under `dataDir/user/` (comfy-cli captures stdout
  there too: `comfy logs`).
- The service binds `listenAddress` per config; firewall is
  `openFirewall`-driven.

## Gotchas

- Workflow files deployed by the installer that diverge from the repo get
  moved aside with a timestamp suffix, not overwritten — check for
  `<name>_<timestamp>.json` sidecars when a "stale" workflow surprises you.