# Fetch-entry constructors for the model fetch service. Each builds a
# pinned fetch entry and injects the token appropriate for its source host
# at eval time — per-source auth is decided here, not guessed at runtime.
# Download entries (cfg.comfyui.downloads) use these; a plain
# { url, sha256 } attrset stays valid for arbitrary URLs (it simply carries
# no token).
{
  config,
  ...
}:
let
  cfg = config.cfg.comfyui;
in
{
  # HuggingFace file, pinned to a repo commit SHA. Emits a tagged entry —
  # the fetcher transports it with the hf CLI (native xet chunks for
  # xet-backed repos, gated-repo auth via HF_TOKEN) and falls back to the
  # resolve URL over curl if the CLI fails. The token (when configured)
  # covers gated repos and is harmless on ungated ones.
  # unzipInto (optional) — same archive-extraction hook as civitaiFetch.
  hfFetch = {
    repo,
    rev,
    file,
    sha256,
    unzipInto ? null,
    # structured destination (see cfg.comfyui.downloads): models/<type>/<arch>/<name>
    # or an explicit dest; both optional — omit for a bare attrset/path key.
    type ? null,
    arch ? [ ],
    name ? null,
    dest ? null,
  }: {
    source = "huggingface";
    inherit repo rev file;
    tokenFile = cfg.huggingfaceTokenFile;
    inherit sha256 unzipInto type arch name dest;
  };

  # CivitAI model version, resolved via the public API
  # (GET https://civitai.com/api/v1/models/<id> → version id + file SHA256).
  # Downloads go through the official civitai CLI (github:civitai/cli, when
  # the consumer passes it via specialArgs) — streamed to a .part file,
  # verified against the server's SHA256, renamed into place — and fall
  # back to the download endpoint over resumable curl; the entry's pinned
  # sha256 gates either way. The key rides along as CIVITAI_TOKEN, never
  # in process arguments. Public models download fine without a key, too.
  # file (optional) selects a specific file in a multi-file version; null
  # takes the version's primary file.
  # unzipInto (optional) extracts a fetched archive — a workflow bundle
  # zip, say — into a dataDir-relative directory on every service start.
  civitaiFetch = {
    versionId,
    sha256,
    file ? null,
    unzipInto ? null,
    # structured destination fields — models/<type>/<arch>/<name>
    type ? null,
    arch ? [ ],
    name ? null,
    dest ? null,
  }: {
    source = "civitai";
    url = "https://civitai.com/api/download/models/${versionId}";
    inherit versionId sha256 file unzipInto type arch name dest;
    tokenFile = cfg.civitaiApiKeyFile;
  };
}
