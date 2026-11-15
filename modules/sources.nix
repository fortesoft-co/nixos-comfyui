# Fetch-entry constructors for cfg.comfyui.downloads. Each builds a
# pinned fetch entry and injects the token appropriate for its source host
# at eval time — per-source auth is decided here, not guessed at runtime.
# modules/downloads.nix turns entries into nixos-model-pins entries,
# which pick the downloader (hf / civitai CLI / curl) automatically. A plain
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
  # HuggingFace file, pinned to a repo commit SHA. Downloaded with
  # `hf download` (curl fallback); the token (when configured) covers
  # gated repos and is harmless on ungated ones.
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

  # CivitAI model version, pinned to versionId. With the API key: the
  # civitai CLI (civitai.red), curl as fallback; without one, curl on the
  # public download endpoint. Sha-gated against the pinned sha256 either
  # way; the key only goes to Civitai's own hosts.
  # file (optional) selects a specific file in a multi-file version; null
  # takes the version's primary file.
  # fileId (optional) — the member's file id: steers a member download on
  # a multi-file version (the report tool emits it for member pins).
  # unzipInto (optional) extracts a fetched archive — a workflow bundle
  # zip, say — into a dataDir-relative directory on every service start.
  # modelId (optional) — the model-page id; lets the update checker skip
  # its per-pin version-id resolution hop; harmless to omit.
  civitaiFetch = {
    versionId,
    sha256,
    file ? null,
    fileId ? null,
    unzipInto ? null,
    modelId ? null,
    # structured destination fields — models/<type>/<arch>/<name>
    type ? null,
    arch ? [ ],
    name ? null,
    dest ? null,
  }: {
    source = "civitai";
    url = "https://civitai.com/api/download/models/${toString versionId}";
    # the report tool and hand-pasted entries may carry the id as int or
    # string — normalize once here so urls and the manifest always see str
    versionId = toString versionId;
    inherit sha256 file fileId unzipInto type arch name dest modelId;
    tokenFile = cfg.civitaiApiKeyFile;
  };
}
