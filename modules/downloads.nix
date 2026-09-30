# Download fetching: multi-GB model files and other artifacts (workflows,
# pose packs, ...) live in a content-addressed store outside the nix
# services. This module composes each download pin's destination, pins the
# resolved entry set as a manifest, and wires three systemd units around
# tools/download_runtime.py:
#
#   <target>-pin-plan  (service user, every boot, oneshot)
#     stat/readlink pass: relink semantic paths whose store blob exists;
#     reconcile/verify foreign files; fetch missing pins into
#     dataDir/.pinwork/staging (sha-gated, resumable); emit promote.json.
#   <target>-pin-seal  (root, oneshot, after plan/audit)
#     the ONLY privileged step: re-measures every staged/adopted file,
#     names bytes by their measured digest, places them into
#     dataDir/store (0444 root:root), writes the provenance sidecar and
#     README, creates the absolute symlinks -- link parent dirs land
#     0775 user:group so foreign writers keep arranging them; blobs stay
#     root:root 0444. No network I/O.
#   <target>-pin-audit (service user, timer cfg.auditSchedule)
#     the ensure pass plus a full sweep of the store: every blob
#     re-measured against its embedded digest; orphans and unrecognized
#     files listed (never deleted).
#
# Store law (the tools/download_runtime.py docstring is the full contract):
#   blob    = dataDir/store/<stem>--<full-sha256><ext>
#   sidecar = <blob>.pin.json            provenance freebie, not load-bearing
#   link    = absolute symlink at models/<type>/<arch>/<name>
#
# Transports: everything is resumable curl against the pinned URL with
# the entry's token (huggingface resolve URLs, the civitai download
# endpoint, plain urls + mirrors). External binaries (curl, openssl,
# coreutils sha256sum) reach the runtime through the units' pinned
# `path` — the host PATH is never trusted under systemd. unzipInto
# bundles keep the real-file handling: fetched into the dest, extracted,
# and re-verified against a checksum manifest on every pass. Entries
# never overwrite existing files; drift is repaired by verified
# replacement, and upstream death leaves local bytes in place and fails
# loudly.
#
# Workflow pins (type = "workflows"): dest names a folder tail under
# <workflowsDir>/nix-managed/pins (default: the entry key) and the
# install is READ-ONLY — the artifact is placed 0444 (a zip is sniffed,
# extracted, and discarded), the namespace's directories re-seal 0555 on
# every pass, and content no longer claimed by a pin is removed. Full
# contract: tools/download_runtime.py docstring.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.cfg.comfyui;

  runtime = pkgs.writers.writePython3Bin "download-runtime" {
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ./../tools/download_runtime.py);

  mkPinStoreUnits =
    {
      dataDir,
      user,
      group ? "comfyui",
      downloads,
      wfpinsRoot,
      enforce ? true,
      auditSchedule ? null,
      mountUnits ? [ ],
      target ? "comfyui",
    }:
    let
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
        else throw "downloads[\"${key}\"]\"]: id-keyed entries need a type+name or a dest";

      entryOf =
        key: dl:
        let
          primaryUrls =
            (lib.optional (dl.source == "civitai" && dl.versionId != null)
              "https://civitai.com/api/download/models/${dl.versionId}")
            ++ (lib.optional
              (dl.source == "huggingface" && dl.repo != null && dl.rev != null)
              "https://huggingface.co/${dl.repo}/resolve/${dl.rev}/${
                lib.optionalString (dl.file != null) dl.file
              }")
            ++ (lib.optional (dl.url != null) dl.url);
          urls = lib.unique (lib.filter (u: u != null && u != "") (
            primaryUrls ++ dl.fallbackUrls
          ));
        in
        {
          id = key;
          kind = if isWorkflows dl then "workflow" else null;
          dest = destOf key dl;
          sha256 = if dl.sha256 != null then dl.sha256 else "";
          tokenFile = dl.tokenFile or null;
          unzipInto = dl.unzipInto or null;
          name = if isWorkflows dl then dl.name else null;
          inherit (dl) fallbackUrls;
          urls = urls;
          legacy =
            if isWorkflows dl then false
            else (dl.unzipInto or null) != null
              || !(lib.hasPrefix "models/" (destOf key dl));
          provenance = lib.filterAttrs (n: v: v != null) {
            source = dl.source;
            inherit (dl) versionId repo rev file;
            url = dl.url;
          };
        };

      entries = lib.mapAttrsToList entryOf downloads;

      badSha = lib.filter (e: !(lib.stringLength e.sha256 == 64)) entries;
      destsList = map (e: e.dest) entries;
      dupDests = lib.filter (d: lib.length (lib.filter (x: x == d) destsList) > 1) (
        lib.unique destsList
      );

      pinManifest = pkgs.writeText "${target}-pins.json" (builtins.toJSON entries);

      storeBin = "${runtime}/bin/download-runtime";
      # The runtime shells out to curl, openssl and coreutils (sha256sum).
      # The units get them through the systemd `path` option — a unit PATH
      # composed of pinned nix store dirs, never the ambient host env.
      toolPath = [ pkgs.curl pkgs.openssl pkgs.coreutils ];
    in
    # The seal unit is declared unconditionally (shape stays
    # config-independent — an optionalAttrs here would recurse into the
    # fixpoint during the module merge); only the audit unit/timer is
    # gated on the schedule.
    {
      assertions = [
        {
          assertion = dupDests == [ ];
          message = "comfyui downloads: duplicate destinations (${lib.concatStringsSep ", " dupDests}) — every entry must resolve to a distinct file";
        }
        {
          assertion =
            badSha == [ ];
          message = "comfyui downloads: every entry must pin a 64-hex sha256 (${lib.concatStringsSep ", " (map (e: e.id) badSha)})";
        }
      ];
      systemd.tmpfiles.rules = [
        # The .pinwork work area belongs to the service user. tmpfiles owns
        # it at every activation, so a root-owned stray (e.g. left behind
        # by the one-time migration, which runs as root) can never wedge
        # the unprivileged boot pass with EACCES.
        "d ${dataDir}/.pinwork 0755 ${user} ${group} - -"
        "d ${dataDir}/.pinwork/staging 0755 ${user} ${group} - -"
        "d ${dataDir}/.pinwork/quarantine 0755 ${user} ${group} - -"
      ];
      systemd.services = {
        "${target}-pin-plan" = {
          description = "Pin-store boot pass (relink, fetch, promote)";
          before = [ "${target}.service" ];
          requiredBy = [ "${target}.service" ];
          after = mountUnits;
          requires = mountUnits;
          path = toolPath;
          serviceConfig = {
            Type = "oneshot";
            User = user;
            TimeoutStartSec = 0;
            ExecStart = "${storeBin} ensure --manifest ${pinManifest} --dataDir ${dataDir} --wfpins ${wfpinsRoot} --jobs 8${lib.optionalString (!enforce) " --no-enforce"}";
          };
        };
        "${target}-pin-seal" = {
          description = "Pin-store placement (root: measure, place, own, link)";
          after = mountUnits ++ [ "${target}-pin-plan.service" ]
            ++ lib.optionals (auditSchedule != null) [ "${target}-pin-audit.service" ];
          requires = mountUnits;
          path = toolPath;
          before = [ "${target}.service" ];
          requiredBy = [ "${target}.service" ];
          serviceConfig = {
            Type = "oneshot";
            User = "root";
            TimeoutStartSec = "15min";
            ExecStart = "${storeBin} seal --manifest ${pinManifest} --dataDir ${dataDir} --link-owner ${user}:${group}";
          };
        };
        "${target}-pin-audit" = lib.mkIf (auditSchedule != null) {
          description = "Pin-store quarterly audit (full sweep + orphans)";
          after = mountUnits ++ [ "${target}-pin-seal.service" ];
          requires = mountUnits;
          path = toolPath;
          conflicts = [ "${target}-pin-plan.service" ];
          wants = [ "${target}-pin-seal.service" ];
          serviceConfig = {
            Type = "oneshot";
            User = user;
            TimeoutStartSec = 0;
            ExecStart = "${storeBin} audit --manifest ${pinManifest} --dataDir ${dataDir} --wfpins ${wfpinsRoot} --jobs 8${lib.optionalString (!enforce) " --no-enforce"}";
          };
        };
      };
      systemd.timers = lib.mkIf (auditSchedule != null) {
        "${target}-pin-audit" = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = auditSchedule;
            Persistent = true;
            Unit = "${target}-pin-audit.service";
          };
        };
      };
    };
in
{
  # Instantiated unconditionally: with an empty list the units are no-ops.
  config = mkPinStoreUnits {
    inherit (cfg) dataDir user group downloads;
    wfpinsRoot = "${cfg.workflowsDir}/nix-managed/pins";
    enforce = cfg.enforcePaths;
    auditSchedule = cfg.auditSchedule;
    mountUnits = cfg.requiresMounts;
  };
}