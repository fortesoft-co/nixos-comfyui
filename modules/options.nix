# Options for the cfg.comfyui interface. Defaults are generic so this
# repository ships as a standalone flake module; the consumer sets concrete
# values. gpuSupport/port/openFirewall/requiresMounts mirror existing
# services.comfyui options — keep the enum in sync with upstream.
{
  lib,
  ...
}:
with lib;
{
  options.cfg.comfyui = {
    dataDir = mkOption {
      type = types.str;
      default = "/var/lib/comfyui";
      description = "ComfyUI data directory (models, user, custom_nodes, input, output).";
    };

    user = mkOption {
      type = types.str;
      default = "comfyui";
      description = ''
        Dedicated unprivileged service account, created by the comfyui-nix
        module with createUser.
      '';
    };

    group = mkOption {
      type = types.str;
      default = "comfyui";
      description = "Primary group for the service account (created with it).";
    };

    gpuSupport = mkOption {
      type = types.enum [
        "cuda"
        "rocm"
        "xpu"
        "none"
      ];
      default = "none";
      description = "GPU acceleration backend for the ComfyUI service.";
    };

    port = mkOption {
      type = types.port;
      default = 8188;
      description = "Port ComfyUI listens on; the MCP tooling drives this.";
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Open the configured port in the firewall (LAN access).";
    };

    requiresMounts = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        Mount units that must be up before ComfyUI (and the model fetcher)
        start — for a data directory on a separate nofail mount. Only
        applied when populated.
      '';
    };

    mcpUsers = mkOption {
      type = with types; listOf str;
      default = [ ];
      description = ''
        Usernames that get the comfy-mcp / comfy-cli binaries on their PATH
        (at /etc/profiles/per-user/<name>/bin). Only applied when populated.
      '';
    };

    enableCivitaiNodes = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Install the official Civitai node pack (in-graph Civitai downloads).
        Its stored key comes from civitaiApiKeyFile when set.
      '';
    };

    enableLoraManager = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Install LoRA Manager (model library UI at /loras — civitai preview
        cards, trigger words, example prompts).
      '';
    };

    enableCrystools = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Install crystools (menu-bar GPU/RAM monitors, progress bars,
        metadata viewer/comparator and misc utility nodes).
      '';
    };

    civitaiApiKeyFile = mkOption {
      type = with types; nullOr str;
      default = null;
      description = ''
        Path to a file containing the Civitai API key (e.g. an agenix
        secret). When set, the Civitai node pack reads its stored key from
        this file instead of the interactive sidebar sign-in.
      '';
    };

    huggingfaceTokenFile = mkOption {
      type = with types; nullOr str;
      default = null;
      description = ''
        Path to a file containing a HuggingFace token (e.g. an agenix
        secret). Wired as HF_TOKEN_PATH for huggingface_hub consumers inside
        the service, and as the fallback bearer token for model fetches
        (per-entry tokenFile overrides it).
      '';
    };

    downloads = mkOption {
      description = ''
        Files fetched into dataDir before the service starts. Keys are paths
        relative to dataDir (e.g. models/checkpoints/...,
        user/default/workflows/...); URLs must point at an immutable
        upstream revision (e.g. an HF commit SHA). Files already present
        are never overwritten; interrupted downloads resume, finished
        downloads are verified against sha256 when one is set, and ZIP
        entries can be extracted with unzipInto.
      '';
      type = types.attrsOf (
        types.submodule {
          options = {
            source = mkOption {
              type = with types; nullOr (enum [ "huggingface" "civitai" ]);
              default = null;
              description = ''
                Fetch transport. null fetches `url` with resumable curl;
                "huggingface" fetches `file` from `repo` at revision `rev`
                with the hf CLI (xet-aware, gated-repo auth) and falls back
                to the resolve URL over curl on failure; "civitai" downloads
                `versionId` (or `file` within the version) through the
                official civitai CLI and falls back to the download endpoint
                over resumable curl on failure.
              '';
            };
            repo = mkOption {
              type = with types; nullOr str;
              default = null;
              description = "HuggingFace repo id, used with source = \"huggingface\".";
            };
            rev = mkOption {
              type = with types; nullOr str;
              default = null;
              description = "HuggingFace revision — a commit SHA, used with source = \"huggingface\".";
            };
            file = mkOption {
              type = with types; nullOr str;
              default = null;
              description = "Repo-relative file path, used with source = \"huggingface\".";
            };
            versionId = mkOption {
              type = with types; nullOr str;
              default = null;
              description = "CivitAI model-version id, used with source = \"civitai\".";
            };
            url = mkOption {
              type = with types; nullOr str;
              default = null;
              description = ''
                Download URL, pinned to a revision. Required unless
                source = "huggingface".
              '';
            };
            sha256 = mkOption {
              type = with types; nullOr str;
              default = null;
              description = "Expected sha256 of the downloaded file; checked when set.";
            };
            fallbackUrls = mkOption {
              type = with types; listOf str;
              default = [ ];
              description = ''
                Mirror URLs tried in order when the primary URL fails or the
                sha256 mismatches — keeps an entry working after its source
                repo removes the file.
              '';
            };
            tokenFile = mkOption {
              type = with types; nullOr str;
              default = null;
              description = ''
                File whose contents are read at fetch time (never stored in
                the nix closure) and sent as a bearer token — enables
                CivitAI and gated-HuggingFace downloads.
              '';
            };
            unzipInto = mkOption {
              type = with types; nullOr str;
              default = null;
              description = ''
                When set, the fetched file is treated as a ZIP archive and
                extracted into this dataDir-relative directory (workflow
                bundles and the like); the archive itself stays where the
                entry's key places it. Extraction runs once per archive
                sha256, and the tree is checksum-manifested and re-verified
                on every boot — drift is repaired by re-extracting.
              '';
            };
          };
        }
      );
      default = { };
    };
  };
}