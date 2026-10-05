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

    enablePanicTitanGallery = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Install PanicTitan ComfyUI-Gallery: a real-time output gallery
        popup inside the frontend (menu button / Ctrl+G) — folder tree,
        search/sort, metadata inspection + raw JSON, move/delete/download
        and batch operations, image/video/GIF/audio/3D display. Its
        settings file (pack-root user_settings.json, written on save) is
        symlinked into <dataDir>/<panicTitanGallerySubdir> — host-writable
        state, not nix.
      '';
    };

    panicTitanGallerySubdir = mkOption {
      type = types.str;
      default = "user/panictitan-gallery";
      description = ''
        dataDir-relative runtime directory holding
        ComfyUI-Gallery's user_settings.json.
      '';
    };

    tokenSpenderSidebarGallerySubdir = mkOption {
      type = types.str;
      default = "user/sidebar-gallery";
      description = ''
        dataDir-relative runtime directory holding TokenSpender
        ComfyUI-Sidebar-Gallery's settings json (sidebar_gallery_config.json),
        its SQLite index (sidebar_gallery_cache.db) and the .thumbs
        thumbnail cache.
      '';
    };

    enableTokenSpenderSidebarGallery = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Install TokenSpender ComfyUI-Sidebar-Gallery: a media browser in
        the ComfyUI sidebar — a persistent SQLite index of the output (and
        extra) folders, embedded generation metadata shown in a searchable
        structured panel (workflow-graph parsing: seed-from-primitive
        resolution, Wan 2.2 MoE high/low pairing, enhanced-vs-original
        prompts), field-prefixed search, a layout editor with named
        presets, workflow loading by dragging thumbnails. Its three
        pack-root runtime items (settings json, cache db, .thumbs) are
        symlinked into <dataDir>/<tokenSpenderSidebarGallerySubdir> —
        host-writable state, not nix.
      '';
    };

    enableMajoorAssetsManager = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Install Majoor Assets Manager: an in-ComfyUI media library (Vue 3
        UI) — browsable outputs/inputs/collections, full-text search +
        filters, the Floating Viewer (live streams, A/B / side-by-side
        compare), Graph Map workflow inspection, a workflow-tab library,
        rating/tag/collection management, and save nodes that embed
        generation_time_ms + prompt + workflow into saved PNG/MP4 files.
        All runtime state lives under the output directory
        (<output>/_mjr_index/) — zero pack-dir writes, so this installs
        as a plain fetched source with no wrapper.
      '';
    };

    enableComfyAssetsPromptManager = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Install ComfyUI PromptManager: a CLIPTextEncode drop-in that
        auto-saves every prompt it encodes to SQLite (sha256-deduped),
        links generated images to prompts, and serves an admin dashboard
        with search, ratings, tags, gallery and export at
        /prompt_manager/admin. Its database, config.json and logs live
        under <dataDir>/<comfyAssetsPromptManagerSubdir> — host-writable
        state, never
        inside nix or any repo.
      '';
    };

    comfyAssetsPromptManagerSubdir = mkOption {
      type = types.str;
      default = "user/prompt-manager";
      description = ''
        dataDir-relative runtime directory for PromptManager — holds
        prompts.db, config.json (seeded, then user-editable through the
        pack-side symlink) and its logs.
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
        Declaratively-pinned files. Keys are entry ids; each entry resolves
        its destination via type + arch + name (models/<type>/<arch>/<name>)
        or an explicit dataDir-relative dest, and names its bytes by their
        sha256 (content-addressed store). Structured models/** entries land
        as absolute symlinks into the root-owned dataDir/store; dest-style
        entries outside models/ and unzipInto bundles keep real-file
        handling. Existing files are never overwritten; missing content is
        fetched with resumable curl (tokenFile bearer auth); drift is
        repaired only after a hash-verified replacement lands.
      '';
      type = types.attrsOf (
        types.submodule {
          options = {
            source = mkOption {
              type = with types; nullOr (enum [ "huggingface" "civitai" ]);
              default = null;
              description = ''
                Fetch transport. null fetches `url` with resumable curl;
                "huggingface" resolves
                https://huggingface.co/<repo>/resolve/<rev>/<file> and
                "civitai" resolves the model-version download endpoint —
                both fetched with resumable curl and the entry's tokenFile
                bearer token (the token covers gated civitai/HF hosts).
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

            # --- destination (structured entries) ---
            type = mkOption {
              type = with types; nullOr str;
              default = null;
              description = ''
                For id-keyed model entries: the ComfyUI models/ subdirectory
                (e.g. "loras", "checkpoints", "diffusion_models") — the
                destination then becomes models/<type>/<arch>/<name>.
                The special value "workflows" marks a read-only workflow
                pin: the entry installs into the nix-managed/pins namespace
                (see dest) instead of models/. Single path segment;
                validated at eval.
              '';
            };

            arch = mkOption {
              type = with types; coercedTo str (a: [ a ]) (listOf str);
              default = [ ];
              description = ''
                Optional architecture/family subpath segment(s) under
                models/<type>/ — e.g. "wan" or ["WanVideo" "Lightx2v"]
                for a two-level family path. Single segments, no slashes.
              '';
            };

            name = mkOption {
              type = with types; nullOr str;
              default = null;
              description = ''
                For model entries: destination basename when the wanted
                local filename differs from the upstream fetched filename.
                For type = "workflows" entries: single-file pins place the
                downloaded file under this name (default: the URL's last
                path segment, else the entry key).
              '';
            };

            dest = mkOption {
              type = with types; nullOr str;
              default = null;
              description = ''
                For model entries: explicit dataDir-relative destination,
                bypassing the models/<type>/<arch>/<name> composition.
                For type = "workflows" entries: an optional folder tail
                under <workflowsDir>/nix-managed/pins (default: the entry
                key) — the fetched artifact (file or zip contents) installs
                read-only into that folder, and a pin removed from the
                manifest removes it. Mutually exclusive with type for model
                entries; for workflows it is the folder tail.
              '';
            };
            versionId = mkOption {
              type = with types; nullOr str;
              default = null;
              description = "CivitAI model-version id, used with source = \"civitai\".";
            };
            modelId = mkOption {
              type = with types; nullOr (either str int);
              default = null;
              description = ''
                Optional CivitAI model-page id (civitaiFetch only). The update
                checker skips its version-id resolution hop for entries that
                carry it; harmless when absent (the tool discovers and caches
                the mapping itself).
              '';
            };
            fileId = mkOption {
              type = with types; nullOr int;
              default = null;
              description = ''
                Optional CivitAI file id (civitaiFetch only): targets a
                specific member of a multi-file version (a gguf quant, a
                vae/encoder bundle member) via a ?fileId download url.
                Omitted entries fetch the version's primary file.
              '';
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
                Legacy extraction: the fetched file is treated as a ZIP and
                extracted into this dataDir-relative directory (plain-file
                entries stay unverified between passes; the archive stays on
                disk). Retired — type = "workflows" extracts any zip at the
                dest automatically, checksum-manifested per file, archive
                discarded, read-only. New entries should not use it.
              '';
            };
          };
        }
      );
      default = { };
    };

    enforcePaths = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Enforce pinned destinations. When true, the boot pass reconciles
        them: wrong or missing links to existing store blobs are relinked,
        and a drifted real file is parked (quarantined) only after its
        verified replacement is staged. When false, existing files/links at
        pinned paths are reported and left exactly as found — the fetch +
        seal pass that places missing content still runs.
      '';
    };

    auditSchedule = mkOption {
      type = with types; nullOr str;
      default = null;
      description = ''
        systemd OnCalendar schedule for <target>-pin-audit — the boot
        ensure pass plus a full sweep of the store (every blob re-measured
        against the digest embedded in its name); orphans and unrecognized
        files are listed, never deleted. null disables the unit and timer.
        Example: "weekly" or "Sun *-01..07 05:00".
      '';
    };

    pinManifestFile = mkOption {
      type = with types; nullOr str;
      default = null;
      internal = true;
      visible = false;
      description = ''
        Internal: the resolved pin manifest (nix store path of
        <target>-pins.json), set by modules/downloads.nix and consumed by
        the read-only reporting module (modules/reporting.nix).
      '';
    };
  };
}
