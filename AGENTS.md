# AGENTS.md

Rules and instructions for agents and humans contributing to this
repository: a standalone NixOS module for declaratively deploying
ComfyUI — service wiring, opt-in node packs, a content-addressed model
store (pin-plan/pin-seal/audit), declarative workflow installation, and
MCP tooling.

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
                       (civitaiFetch takes an optional modelId — lets the
                       update checker skip its version-id resolution hop)
modules/downloads.nix  pin manifest + pin-plan/pin-seal/pin-audit systemd
                       units around tools/download_runtime.py
                       (content-addressed dataDir/store)
modules/nodes.nix      opt-in node packs (enable* flags)
modules/workflows.nix  declarative workflow installation (read-only mirror:
                       repo/ subtree under <workflowsDir>/nix-managed)
modules/mcp.nix        comfy-mcp + comfy-cli for mcpUsers
modules/reporting.nix  read-only store reporting + civitai update
                       checker (tools/report_runtime.py); drops
                       <dataDir>/nixos-comfyui-tools/comfyui-report, a
                       tmpfiles symlink recreated at every rebuild
                       (dataDir-owned tree — tmpfiles cannot place
                       anything under the root-owned store/)
tools/
download_runtime.py    download runtime (ensure/seal/audit; type="workflows"
                       pins land read-only in the pins/ subtree with
                       per-file checksum state in .pinwork/wf-pin-state)
report_runtime.py      read-only reporting/update checker (report |
                       updates subcommands; api GETs only, store bytes
                       never touched — updates writes report + staging
                       .nix files into its working directory)
workflow_runtime.py    workflow mirror pass (repo/ subtree, 0444/0555)
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
   `rm` service files; the pin-store pipeline (plan/seal) + UI tooling are
   the writers, and store blobs are root-owned `0444` — a deleted blob is
   re-downloadable, but never delete on spec.
4. **Flakes + new files**: after adding anything under a directory the eval
   reads (workflows dir, module files), `git add` before the next
   `nix eval`/rebuild.
5. **Conflict-safe everywhere**: the pin-store pipeline never touches
   existing store blobs (placements are by content digest, and drifted
   real files are parked under `.pinwork/quarantine/`, only after their
   verified replacement is staged); the workflow installer only ever
   writes inside its mirror namespace (`<workflowsDir>/nix-managed/`,
   read-only 0444/0555) and never rewrites anything a user can edit.
   Local edits are never lost.
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
   — the `workflowDirs` mapping mirrors it read-only into
   `user/default/workflows/nix-managed/` on next rebuild.

The mirror is enforced by directory modes (files 0444, directories 0555
   between passes): ComfyUI saves via `mkstemp`+`os.replace`, so sealing
   the directory is what makes in-place saves of mirror files fail loudly.
   Anything the mirror previously managed but no longer in the manifest is
   auto-removed on the next pass.

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
- Workflow pins are `type = "workflows"` entries: an optional `dest`
  folder tail (default: the entry key) plus an optional `name` for the
  placed file. The artifact installs read-only under
  `<workflowsDir>/nix-managed/pins/<dest>` — zips are sniffed, extracted
  and discarded; the sha256 stays the fetch gate. One entry owns one
  folder; a dropped pin's folder is swept on the next boot (content
  lives in the consumer git history).

## Pin store ops

`comfyui-pin-plan` (boot, service user) relinks and fetches;
`comfyui-pin-seal` (root, placement + ownership only) lands blobs and
links; `comfyui-pin-audit` (OnCalendar timer via `auditSchedule`) sweeps
the whole store and reports orphans. If entries were added since the last
boot: `sudo systemctl start comfyui-pin-plan` (the seal follows via the
unit graph; run `sudo systemctl start comfyui-pin-seal` by hand when
needed). Ensure **fails as a unit** if any pin cannot be satisfied — a bad
pin blocks the boot pass — so verify hashes before pinning and use
`fallbackUrls` for fragile sources. Store blobs are root:root 0444 under
`dataDir/store`; `models/**` entries are absolute symlinks: moved links are
relinked on the next pass, deleted blobs are re-fetched. Seal also
re-asserts 0444 root:root across the store on every pass.

Store reporting: `<dataDir>/nixos-comfyui-tools/comfyui-report report|updates` —
read-only against the store, no sudo; `updates` paces civitai API reads,
honors 429/Retry-After, sends tokenized requests to civitai.red first,
resolves hf pins via the by-hash index (`--include-hf`), and writes
`comfyui-updates.md` plus staging modules into the running directory:
`comfyui-updates-lm-parity.nix` (the loras/checkpoints/embeddings set,
matching what Lora Manager's update view shows),
`comfyui-updates-other.nix` (everything else), and
`comfyui-updates-verify-first.nix` (entries carrying a shared-candidate
or non-primary verification tell — inspect, never blind-paste).
`.lastrun.json` short-circuits same-day reruns; `--fresh` rechecks.

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

- ComfyUI's userdata saves are `mkstemp`+`os.replace` — a 0444 file does
  NOT block them; the 0555 *directory* under
  `<workflowsDir>/nix-managed/` is the gate. Old timestamped workflow
  sidecars in `user/workflow-backups/` predate the mirror scheme and can
  be deleted by hand.