# Download pins: multi-GB model files and other artifacts (workflows,
# pose packs, ...) live in a content-addressed store outside the nix
# store, managed by nixos-model-pins (github:fortesoft-co/nixos-model-pins).
# This module only maps cfg.comfyui onto one model-pins instance,
# cfg.model-pins.instances.comfyui:
#
#   - destinations: models/<type>/<arch>/<name>, an explicit dest, or a
#     folder under <workflowsDir>/nix-managed/pins for type = "workflows"
#     (composed here — the folder default needs the entry key)
#   - entries: each cfg.comfyui.downloads entry becomes a model-pins
#     hfFetch / civitaiFetch / urlFetch entry; dests outside models/ and
#     unzipInto bundles keep real-file handling (inPlace)
#   - tokens: huggingfaceTokenFile / civitaiApiKeyFile are the instance's
#     per-source tokenFiles
#   - policy: enforcePaths, auditSchedule, requiresMounts; comfyui.service
#     consumes the instance
#
# Units, store law, transports (hf / civitai CLI / curl) and the runtime
# are nixos-model-pins': comfyui-models-fetch (service user),
# comfyui-models-install (root, placement only) and, with auditSchedule,
# comfyui-models-verify. Full contract: the model-pins runtime docstring.
#
# Reporting companion: the resolved manifest is exposed at the internal
# option cfg.comfyui.pinManifestFile for modules/reporting.nix.
{
  config,
  lib,
  # nixos-model-pins' constructors, set by this flake's
  # nixosModules.default (which also imports the model-pins module)
  modelPinsLib,
  ...
}:
let
  cfg = config.cfg.comfyui;

  # Single-instance assumption: one comfyui install (one manifest, one
  # reporting tool) per host, matching the reporting module.
  instance = "comfyui";
  wfpinsRoot = "${cfg.workflowsDir}/nix-managed/pins";

  # Destination resolution — same contract as before: explicit dest,
  # or models/<type>/<arch segments>/<name> for structured pins. type
  # = "workflows" composes a folder under the nix-managed/pins
  # read-only namespace instead. The manifest carries the composed
  # dataDir-relative dest; the runtime does the rest.
  segOk =
    s: s != "" && s != "." && !lib.hasInfix "/" s && !lib.hasInfix ".." s;

  isWorkflows = dl: dl.type != null && dl.type == "workflows";

  wfFolderOf =
    key: dl:
    let
      tail = lib.filter (s: s != "") (
        lib.splitString "/" (if dl.dest != null then dl.dest else key)
      );
    in
    if dl.unzipInto != null then
      throw "downloads[\"${key}\"]: unzipInto is retired — type = \"workflows\" extracts any zip at the dest automatically"
    else if dl.arch != [ ] then
      throw "downloads[\"${key}\"]: arch has no meaning for type = \"workflows\""
    else if dl.name != null && !segOk dl.name then
      throw "downloads[\"${key}\"]: name must be a single path segment"
    else if tail == [ ] then
      throw "downloads[\"${key}\"]: workflow entries need a dest folder tail (or a usable key)"
    else if !lib.all segOk tail then
      throw "downloads[\"${key}\"]: dest folder needs plain single segments (${lib.concatStringsSep "/" tail})"
    else if lib.elem "nix-managed" tail then
      throw "downloads[\"${key}\"]: the segment \"nix-managed\" is reserved for the read-only namespace"
    else lib.concatStringsSep "/" tail;

  destOf =
    key: dl:
    if isWorkflows dl then
      "${wfpinsRoot}/${wfFolderOf key dl}"
    else if dl.dest != null then
      dl.dest
    else if dl.type != null then
      if dl.name == null then
        throw "downloads[\"${key}\"]: structured entry (type set) needs a name"
      else if !lib.all segOk ([ dl.type ] ++ dl.arch ++ [ dl.name ]) then
        throw "downloads[\"${key}\"]: type/arch/name must be single path segments"
      else lib.concatStringsSep "/" ([ "models" dl.type ] ++ dl.arch ++ [ dl.name ])
    else throw "downloads[\"${key}\"]: id-keyed entries need a type+name or a dest";

  # cfg.comfyui.downloads entry -> model-pins entry (via its constructors)
  pinOf =
    key: dl:
    let
      dest = destOf key dl;
      wf = isWorkflows dl;
      need =
        fields:
        let
          missing = lib.filter (f: dl.${f} == null) fields;
        in
        if missing != [ ] then
          throw "downloads[\"${key}\"]: source = \"${dl.source}\" needs ${lib.concatStringsSep ", " missing}"
        else
          lib.getAttrs fields dl;
      common = {
        sha256 = if dl.sha256 != null then dl.sha256 else "";
        inherit dest;
        inherit (dl) tokenFile fallbackUrls unzipInto;
        # real-file handling outside the models/ store links
        inPlace = !wf && (dl.unzipInto != null || !lib.hasPrefix "models/" dest);
        kind = if wf then "workflow" else null;
        name = if wf then dl.name else null;
      };
    in
    if dl.source == "huggingface" then
      modelPinsLib.hfFetch (common // need [ "repo" "rev" "file" ])
    else if dl.source == "civitai" then
      modelPinsLib.civitaiFetch (
        common
        // need [ "versionId" ]
        // {
          inherit (dl) fileId file modelId;
        }
      )
    else if dl.url != null then
      modelPinsLib.urlFetch (common // { inherit (dl) url; })
    else
      throw "downloads[\"${key}\"]: needs a source (hfFetch / civitaiFetch) or a url";
in
{
  config = {
    cfg.model-pins.instances.${instance} = {
      inherit (cfg) dataDir user group requiresMounts;
      workflowsDir = wfpinsRoot;
      enforce = cfg.enforcePaths;
      verifySchedule = cfg.auditSchedule;
      consumedBy = [ "comfyui.service" ];
      tokenFiles = {
        huggingface = cfg.huggingfaceTokenFile;
        civitai = cfg.civitaiApiKeyFile;
      };
      downloads = lib.mapAttrs pinOf cfg.downloads;
    };
    # The resolved manifest is the reporting module's data source
    # (internal option, declared in modules/options.nix).
    cfg.comfyui.pinManifestFile = config.cfg.model-pins.pinManifestFiles.${instance};
  };
}
