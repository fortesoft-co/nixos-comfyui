# Pin-store reporting + update checks: a read-only companion module.
#
# Instantiated unconditionally alongside modules/downloads.nix; it adds no
# units and owns nothing but tmpfiles rules that drop the reporting tool
# into <dataDir>/nixos-comfyui-tools/comfyui-report — a symlink to this
# nix-store binary, recreated at every activation (i.e. every rebuild), so
# the tool always tracks the current manifest and dataDir without a
# refresh step. (The dir is named for the module repo, not the tool.)
#
# The tool lives under dataDir/nixos-comfyui-tools, NOT inside the store:
# the dataDir tree is service-user-owned while the store is root-owned by
# design, and systemd-tmpfiles refuses any entry whose path crosses that
# ownership handoff ("Detected unsafe path transition") — so a
# store-placed symlink can never be applied by an activation.
#
# The tool (tools/report_runtime.py) never writes store bytes and never
# needs elevated permissions: subcommand `report` classifies local state
# (current/adoptable/link-drift/fetch-pending/impostor, store orphans,
# dedup, strays) with no network access; subcommand `updates` checks every
# civitai-sourced pin against the civitai API (paced, cached, tokenized
# requests go mirror-first) plus hf pins via the by-hash index, and writes
# its report + paste-ready staging nix modules into the running directory
# (full contract: tools/report_runtime.py docstring). No host values live
# here: dataDir and the manifest path flow from cfg.comfyui at eval time
# and are baked in as argument defaults; --manifest/--dataDir/--token-file
# override.
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
    # nixos-comfyui-tools/ sits in the service-user-owned dataDir namespace —
    # the same ownership all the way down, so no unsafe-path transition
    # blocks the run. L+ recreates the symlink on every activation, always
    # pointing at the fresh build.
    "d ${cfg.dataDir}/nixos-comfyui-tools 0755 ${cfg.user} ${cfg.group} - -"
    "L+ ${cfg.dataDir}/nixos-comfyui-tools/comfyui-report - - - - ${reportTool}/bin/comfyui-report"
    # Retires the pre-rename placement: its symlink, then the dir once it
    # is empty. Runs at every activation; no-ops once both are gone.
    "r ${cfg.dataDir}/bin/comfyui-report"
    "r ${cfg.dataDir}/bin"
  ];
}