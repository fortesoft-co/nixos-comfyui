# ComfyUI service module: orchestration + defaults only.
#
# Wraps the native NixOS module from github:utensils/comfyui-nix and adds:
#   - the cfg.comfyui.* interface (declared in ./modules/options.nix, generic
#     defaults)
#   - comfy-mcp/comfy-cli tooling on mcpUsers' PATH (./modules/mcp.nix)
#   - the model fetch oneshot (./modules/downloads.nix, constructors in
#     ./modules/sources.nix)
#   - custom node declarations (./modules/nodes.nix)
#   - declarative workflow installation (./modules/workflows.nix)
#
# No host assumptions live here: machine-specific values (dataDir, mounts,
# group, enable flags) are set by the consumer — a consumer module that
# imports this one and passes `comfyui-nix` via specialArgs. That keeps this
# repository shippable as a standalone flake module (see ./flake.nix and
# ./README.md).
{
  config,
  lib,
  comfyui-nix,
  ...
}:
let
  cfg = config.cfg.comfyui;
in
{
  imports = [
    comfyui-nix.nixosModules.default
    ./modules/options.nix
    ./modules/mcp.nix
    ./modules/downloads.nix
    ./modules/nodes.nix
    ./modules/workflows.nix
  ];

  # ComfyUI binary cache (https://github.com/utensils/comfyui-nix), mostly for
  # the pre-built CUDA/torch wheels pulled in by services.comfyui.
  nix.settings.extra-substituters = [ "https://comfyui.cachix.org" ];
  nix.settings.extra-trusted-public-keys = [
    "comfyui.cachix.org-1:33mf9VzoIjzVbp0zwj+fT51HG0y31ZTK3nzYZAX0rec="
  ];

  # Default setup: the wrapper turns the service on with a dedicated
  # unprivileged account (created by the module, home set to dataDir) and the
  # Manager UI the MCP/Krita tooling assumes.
  services.comfyui = {
    enable = true;
    createUser = true;
    enableManager = true;

    gpuSupport = cfg.gpuSupport;
    port = cfg.port;
    openFirewall = cfg.openFirewall;
    dataDir = cfg.dataDir;
    user = cfg.user;
    group = cfg.group;

    # Only applied when populated (nofail mounts shouldn't gate a machine
    # without them).
    requiresMounts = lib.mkIf (cfg.requiresMounts != [ ]) cfg.requiresMounts;

    # Runtime HF access for huggingface_hub consumers inside the service
    # (controlnet_aux annotator downloads, PuLID's EVA-CLIP fetch, Civitai
    # pack HF downloads).
    environment = lib.mkIf (cfg.huggingfaceTokenFile != null) {
      HF_TOKEN_PATH = cfg.huggingfaceTokenFile;
    };
  };
}