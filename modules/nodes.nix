# Custom node defaults for the module: the flake's bundled set plus three
# opt-in packs, each behind a cfg.comfyui option (all default false):
#   civitai-comfy-nodes — official Civitai pack (in-graph model downloads)
#   lora-manager        — model library UI at /loras (civitai previews,
#                         trigger words, example prompts; resolves metadata
#                         by file sha256, so models fetched outside it match
#                         automatically)
#   comfyui-crystools   — GPU/RAM menu-bar monitors, progress bars, metadata
#                         viewer/comparator and misc utility nodes
# Host-specific nodes are declared by the consumer:
# services.comfyui.customNodes is an attrset, so entries merge.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.cfg.comfyui;
in
{
  services.comfyui = {
    # Flake-bundled custom nodes (Impact Pack, KJNodes, ComfyUI-GGUF, rgthree,
    # LTXVideo, Florence2, bitsandbytes NF4, x-flux, MMAudio, PuLID,
    # WanVideoWrapper) are symlinked into custom_nodes/ at service start and
    # versioned with the flake pin — declarative, no runtime installs. The
    # launcher's deletion is name-scoped: it only rm -rf's a real (non-symlink)
    # directory whose NAME matches one of the bundled nodes, so git clones and
    # runtime Manager installs under other names are untouched. Avoid declaring
    # a customNodes entry under a bundled name — the launcher's symlink would
    # overwrite it at startup.
    bundledCustomNodes = true;

    customNodes = lib.mkMerge [
      # Official Civitai node pack: loaders with built-in Civitai browsing
      # that download on demand as part of a workflow run — graph-node based,
      # so MCP-driven workflows can pull models directly. Pinned to upstream
      # HEAD; bump rev + hash together.
      (lib.mkIf cfg.enableCivitaiNodes {
        civitai-comfy-nodes = pkgs.fetchFromGitHub {
          owner = "civitai";
          repo = "civitai-comfy-nodes";
          rev = "1bcb19524567b1c821b8e24a92e198a6e3c0858f";
          hash = "sha256-BANzLOP5ULikRgVrIYnMfUZyvDlXrrylq6910IOP3qM=";
        };
      })

      # LoRA/checkpoint library manager: card grid with civitai previews,
      # trigger words, example prompts and one-click loader integration at
      # http://<host>:<port>/loras. Settings, DB and .metadata.json sidecars
      # live in the writable user dir / models dirs (nix store copy is
      # read-only but never written). Its civitai key is set once in its own
      # settings page (separate store from the Civitai pack's env key).
      (lib.mkIf cfg.enableLoraManager {
        lora-manager = pkgs.fetchFromGitHub {
          owner = "willmiao";
          repo = "ComfyUI-Lora-Manager";
          rev = "521531111a071e5ec6db02813e6c9a6438396b07";
          hash = "sha256-45QVOi8BVn2CeZ0p3+RNbhBx1InBHge/+swSJi7H/1A=";
        };
      })

      # crystools: menu-bar GPU/RAM monitors and utility nodes. The last
      # upstream commit (v1.27.4) is the fix for the current frontend, so
      # pinning HEAD is the stable choice.
      (lib.mkIf cfg.enableCrystools {
        comfyui-crystools = pkgs.fetchFromGitHub {
          owner = "crystian";
          repo = "comfyui-crystools";
          rev = "2f18256c5b5063937106f29a8e0a7db3ae3869b7";
          hash = "sha256-IvLgvudqJV6QeNxwA3HbIlGxShCfUBBSZ8DSjOVlSyE=";
        };
      })
    ];

    # Python deps: socketio (client) for the Civitai pack; the second list is
    # LoRA Manager's requirements.txt minus core-env entries (aiohttp,
    # safetensors, Pillow, numpy are hard comfyui deps); the third is
    # crystools' requirements (torch/numpy/Pillow already in the core env;
    # pynvml gives the NVIDIA stats). Redundant entries are harmless — the
    # python env dedupes.
    extraPythonPackages =
      ps:
      lib.optional cfg.enableCivitaiNodes ps.python-socketio
      ++ lib.optionals cfg.enableLoraManager [
        ps.aiohttp-socks
        ps.aiosqlite
        ps.beautifulsoup4
        ps.brotli
        ps.gitpython
        ps.jinja2
        ps.natsort
        ps.olefile
        ps.piexif
        ps.platformdirs
        ps.toml
        ps.pyyaml
      ]
      ++ lib.optionals cfg.enableCrystools [
        ps.deepdiff
        ps.pynvml
        ps.py-cpuinfo
        ps.piexif
      ];

    # Point the pack's stored-key path at the agenix-decrypted file when
    # provided — its reads treat the file's contents as the API key, so the
    # interactive sidebar sign-in is never needed.
    environment = lib.mkIf (cfg.enableCivitaiNodes && cfg.civitaiApiKeyFile != null) {
      CIVITAI_COMFY_API_KEY_STORE = cfg.civitaiApiKeyFile;
    };
  };
}