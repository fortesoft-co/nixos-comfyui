# Declarative workflow installation: cfg.comfyui.workflows maps paths
# relative to dataDir (e.g. user/default/workflows/...) to store-path files
# (e.g. ./workflows/foo.json in the consumer). A oneshot installs
# each into place before the service starts:
#
#   missing            -> installed
#   byte-identical     -> left alone
#   divergent (edited) -> the existing copy is moved aside to
#                         <name>_<timestamp>.json and the repo version
#                         installed — local edits are never lost
#
# Sources must be UI-format graphs (nodes/links) — the workflow browser
# only renders those. tools/workflow_api_to_ui.py converts API-format
# graphs while authoring (it needs the running server's object_info, so
# conversion is an authoring-time step, not a systemd-time one).
#
# The convenience path: cfg.comfyui.workflowDirs — point it at local
# directories and the whole tree is mapped under the install root
# (cfg.comfyui.workflowsDir, preserving subdirectories).
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.cfg.comfyui;

  # Walk a directory into { "<install-root>/<subpath>" = <path>; }, skipping
  # dotfiles. Returns a list of attrsets (one attrset per entry) so callers
  # can lib.mkMerge the results.
  walkWorkflows =
    dir: prefix:
    lib.concatLists (
      lib.mapAttrsToList (
        name: type:
        if type == "directory" then
          walkWorkflows "${dir}/${name}" (
            if prefix == "" then name else "${prefix}/${name}"
          )
        else if lib.hasPrefix "." name || !lib.hasSuffix ".json" name then
          [ ]
        else
          [ { "${cfg.workflowsDir}/${prefix}/${name}" = "${dir}/${name}"; } ]
      ) (builtins.readDir dir)
    );
in
{
  options.cfg.comfyui.workflowsDir = lib.mkOption {
    type = lib.types.str;
    default = "user/default/workflows";
    description = "dataDir-relative root the workflow files install into.";
  };

  options.cfg.comfyui.workflowBackupDir = lib.mkOption {
    type = lib.types.str;
    default = "user/workflow-backups";
    description = ''
      dataDir-relative directory where displaced workflow copies (a deployed
      file diverging from the repo version) are moved. Kept outside the
      workflows root so stale versions don't clutter the UI's workflow
      browser — they are history, not current workflows.
    '';
  };

  options.cfg.comfyui.workflows = lib.mkOption {
    description = ''
      Workflow files installed into dataDir. Keys are paths relative to
      dataDir (e.g. user/default/workflows/edit/foo.json); values are
      store paths (e.g. ./workflows/foo.json in the consumer).
      Existing files are never overwritten — same semantics as downloads.
      Sources must be UI-format graphs.
    '';
    type = lib.types.attrsOf lib.types.path;
    default = { };
  };

  options.cfg.comfyui.workflowDirs = lib.mkOption {
    type = lib.types.listOf lib.types.path;
    default = [ ];
    description = ''
      Local directories of UI-format workflow files (.json). The full tree
      of each directory is mapped under cfg.comfyui.workflowsDir,
      preserving subdirectories.
    '';
  };

  config = lib.mkMerge [
    { cfg.comfyui.workflows = lib.mkMerge (map (dir: lib.foldr (a: b: a // b) { } (walkWorkflows dir "")) cfg.workflowDirs); }
    (lib.mkIf (cfg.workflows != { }) {
      systemd.services.comfyui-workflows-install = {
        description = "Install declarative ComfyUI workflows";
        after = [ "comfyui-download-fetch.service" ] ++ cfg.requiresMounts;
        before = [ "comfyui.service" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          User = cfg.user;
          Group = cfg.group;
          UMask = "0002";
          RemainAfterExit = true;
        };
        script = lib.concatStringsSep "\n" (
          lib.mapAttrsToList (key: file: ''
            dst="${cfg.dataDir}/${key}"
            src="${file}"
            if [ ! -e "$dst" ]; then
              ${pkgs.coreutils}/bin/install -D -m 0644 "$src" "$dst"
            elif ! ${pkgs.diffutils}/bin/cmp -s "$dst" "$src"; then
              bak="${cfg.dataDir}/${cfg.workflowBackupDir}/$(${pkgs.coreutils}/bin/date +%Y%m%d_%H%M%S)_$(${pkgs.coreutils}/bin/basename "$dst")"
              ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "$bak")"
              ${pkgs.coreutils}/bin/mv "$dst" "$bak"
              ${pkgs.coreutils}/bin/install -D -m 0644 "$src" "$dst"
              echo "workflow updated: ${key} (previous copy: $bak)"
            fi
          '') cfg.workflows
        );
      };
    })
  ];
}