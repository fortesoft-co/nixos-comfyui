# Declarative workflow installation: managed workflows install READ-ONLY.
#
# cfg.comfyui.workflows maps paths relative to dataDir (e.g.
# user/default/workflows/...) to store-path files (e.g. ./workflows/foo.json
# in the consumer). A oneshot mirrors each entry into the pass-owned
# directory <workflowsDir>/nix-managed/repo/<subpath> before the service
# starts — one of two sibling namespaces under the shared nix-managed root
# (downloads' type="workflows" pins own the pins/ sibling):
#
#   missing        -> copied in (0444)
#   byte-identical -> left alone
#   different      -> rewritten (0444): the mirror always tracks the repo
#   unclaimed      -> removed: the mirror is nix's namespace; dropped
#                     entries survive only in the consumer git history
#
# Between passes every directory under the mirror root is mode 0555 and
# every file 0444 — ComfyUI's userdata API saves via mkstemp+os.replace,
# which requires only DIRECTORY write, so sealing the directory is what
# makes in-place saves fail loudly (the mirror can still be listed and
# opened). The workflows root itself is never rewritten: everything outside
# nix-managed/ belongs to the user, to edit and Save As freely.
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

  runtime = pkgs.writers.writePython3Bin "workflow-mirror" {
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ./../tools/workflow_runtime.py);

  # The reserved segment: mirror installs live one level below the browsed
  # root, under repo/ — a sibling of downloads' pins/ namespace (the shared
  # nix-managed root is widened + re-sealed by every runtime that touches
  # it). Consumer content must never cross "nix-managed" segments.
  managedDir = "${cfg.workflowsDir}/nix-managed";
  repoDir = "${managedDir}/repo";

  destOf =
    key:
    let
      tail = lib.concatStringsSep "/" (
        lib.filter (s: s != "") (lib.splitString "/" (lib.removePrefix cfg.workflowsDir key))
      );
    in
    if !lib.hasPrefix "${cfg.workflowsDir}/" key then
      throw "comfyui-workflows[\"${key}\"]: managed workflows must sit under workflowsDir (\"${cfg.workflowsDir}\")"
    else if lib.elem "nix-managed" (lib.splitString "/" tail) then
      throw "comfyui-workflows[\"${key}\"]\"]: the path segment \"nix-managed\" is reserved for the read-only mirror"
    else "${repoDir}/${tail}";

  manifest = pkgs.writeText "comfyui-workflows.json" (
    builtins.toJSON (
      lib.mapAttrsToList (key: file: {
        id = key;
        dest = destOf key;
        src = "${file}";
      }) cfg.workflows
    )
  );
in
{
  options.cfg.comfyui.workflowsDir = lib.mkOption {
    type = lib.types.str;
    default = "user/default/workflows";
    description = "dataDir-relative root the workflow mirror nests under (the mirror installs into <this>/nix-managed).";
  };

  options.cfg.comfyui.workflows = lib.mkOption {
    description = ''
      Workflow files mirrored into dataDir. Keys are paths relative to
      dataDir under cfg.comfyui.workflowsDir (e.g.
      user/default/workflows/edit/foo.json); values are store paths (e.g.
      ./workflows/foo.json in the consumer). Entries install read-only
      under <workflowsDir>/nix-managed/ as exact mirrors of the repo
      content — anything unclaimed is removed, and the mirror is never
      edited in place (saves into it fail). Sources must be UI-format
      graphs.
    '';
    type = lib.types.attrsOf lib.types.path;
    default = { };
  };

  options.cfg.comfyui.workflowDirs = lib.mkOption {
    type = lib.types.listOf lib.types.path;
    default = [ ];
    description = ''
      Local directories of UI-format workflow files (.json). The full tree
      of each directory is mirrored under <workflowsDir>/nix-managed,
      preserving subdirectories.
    '';
  };

  config = lib.mkMerge [
    { cfg.comfyui.workflows = lib.mkMerge (map (dir: lib.foldr (a: b: a // b) { } (walkWorkflows dir "")) cfg.workflowDirs); }
    (lib.mkIf (cfg.workflows != { }) {
      systemd.services.comfyui-workflows-install = {
        description = "Mirror declarative ComfyUI workflows (read-only)";
        after = [ "comfyui-pin-seal.service" ] ++ cfg.requiresMounts;
        before = [ "comfyui.service" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          User = cfg.user;
          Group = cfg.group;
          UMask = "0002";
          RemainAfterExit = true;
          ExecStart = "${runtime}/bin/workflow-mirror --manifest ${manifest} --dataDir ${cfg.dataDir} --managed ${repoDir}";
        };
      };
    })
  ];
}