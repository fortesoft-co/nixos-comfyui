# Pin-store reporting + update checks: a read-only companion module.
#
# Instantiated unconditionally alongside modules/downloads.nix; it adds no
# units and owns nothing but a tmpfiles rule that drops the reporting tool
# into <dataDir>/bin/comfyui-report — a symlink to this nix-store binary,
# recreated at every activation (i.e. every rebuild), so the tool always
# tracks the current manifest and dataDir without a refresh step.
#
# The tool lives under dataDir/bin, NOT inside the store: the dataDir tree
# is service-user-owned while the store is root-owned by design, and
# systemd-tmpfiles refuses any entry whose path crosses that ownership
# handoff ("Detected unsafe path transition") — so a store-placed symlink
# can never be applied by an activation.
#
# The tool (tools/report_runtime.py) never writes store bytes and never
# needs elevated permissions: subcommand `report` classifies local state
# (current/adoptable/link-drift/fetch-pending/impostor, store orphans,
# dedup, strays) with no network access; subcommand `updates` additionally
# checks every civitai-sourced pin against the civitai API (paced, cached,
# one mirror fallback on 403/404) and can print paste-ready download
# entries (--nix-snippets). No host values live here: dataDir and the
# manifest path flow from cfg.comfyui at eval time and are baked in as
# argument defaults; --manifest/--dataDir/--token-file override.
{ config, pkgs, lib, ... }:
let
  cfg = config.cfg.comfyui;

  reportTool = pkgs.writers.writePython3Bin "comfyui-report" {
    flakeIgnore = [ "E501" ];
  } (
    lib.replaceStrings
      [ "@MANIFEST@" "@DATA_DIR@" ]
      [ (if cfg.pinManifestFile == null then "" else cfg.pinManifestFile) cfg.dataDir ]
      (builtins.readFile ./../tools/report_runtime.py)
  );
in
{
  systemd.tmpfiles.rules = [
    # `bin/` sits in the service-user-owned dataDir namespace — the same
    # ownership all the way down, so no unsafe-path transition blocks the
    # run. L+ recreates the symlink on every activation, always pointing
    # at the fresh build.
    "d ${cfg.dataDir}/bin 0755 ${cfg.user} ${cfg.group} - -"
    "L+ ${cfg.dataDir}/bin/comfyui-report - - - - ${reportTool}/bin/comfyui-report"
  ];
}