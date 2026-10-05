# Fetch-entry constructors for cfg.comfyui.downloads. Each builds a
# pinned fetch entry and injects the token appropriate for its source host
# at eval time — per-source auth is decided here, not guessed at runtime.
# Transports are resumable curl against the pinned URL (see
# modules/downloads.nix and tools/download_runtime.py). A plain
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
  # HuggingFace file, pinned to a repo commit SHA. The resolve URL is
  # fetched with resumable curl; the token (when configured) is a bearer
  # header that covers gated repos and is harmless on ungated ones.
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

  # CivitAI model version, resolved via the download endpoint
  # (https://civitai.com/api/download/models/<versionId>). Fetched with
  # resumable curl to a .part file, sha-gated against the entry's pinned
  # sha256, then placed; the API key rides along as a bearer header on the
  # initial request (the CDN redirect is signed). Public models download
  # fine without a key, too.
  # file (optional) selects a specific file in a multi-file version; null
  # takes the version's primary file.
  # fileId (optional) — the member's file id, making the fetch url
  # ?fileId=<id>: required to actually steer a member download on a
  # multi-file version (the report tool emits it for member pins).
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
