# Custom node defaults for the module: the flake's bundled set plus opt-in
# packs, each behind a cfg.comfyui option (all default false):
#   civitai-comfy-nodes — official Civitai pack (in-graph model downloads)
#   lora-manager        — model library UI at /loras (civitai previews,
#                         trigger words, example prompts; resolves metadata
#                         by file sha256, so models fetched outside it match
#                         automatically)
#   comfyui-crystools   — GPU/RAM menu-bar monitors, progress bars, metadata
#                         viewer/comparator and misc utility nodes
#   prompt-manager      — prompt auto-capture to SQLite (CLIPTextEncode
#                         drop-in, /prompt_manager/admin dashboard,
#                         PromptSearchList batch node); DB/config/logs
#                         live under <dataDir>/<comfyAssetsPromptManagerSubdir>
#   comfyui-gallery     — real-time output gallery popup (PanicTitan:
#                         folder tree, metadata/batch ops); settings file
#                         symlinked under <dataDir>/<panicTitanGallerySubdir>
#   sidebar-gallery     — sidebar media browser (TokenSpender: SQLite
#                         index + workflow-graph metadata parser);
#                         config/cache/thumbs symlinked under
#                         <dataDir>/<tokenSpenderSidebarGallerySubdir>
#   majoor-assets       — Majoor Assets Manager (media library, Floating
#                         Viewer, Graph Map, save nodes w/ embedded
#                         generation timing; all state in
#                         <output>/_mjr_index/ — no pack writes, no
#                         wrapper)
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

  # ComfyUI PromptManager (enableComfyAssetsPromptManager): its runtime writes are
  # repointed under this host-writable dir — prompts.db (absolute path via
  # the seeded config.json), config.json itself (symlinked so dashboard
  # settings persist), logs (symlink; the pack opens its rotating file
  # handler at import time, so the target must pre-exist) and data/
  # (symlink; LoRA-image import cache). Pre-created via tmpfiles below.
  promptManagerRuntimeDir = "${cfg.dataDir}/${cfg.comfyAssetsPromptManagerSubdir}";
  promptManagerConfigSeed = pkgs.writeText "prompt-manager-config.json" (
    builtins.toJSON {
      database.default_path = "${promptManagerRuntimeDir}/prompts.db";
    }
  );

  # PanicTitan ComfyUI-Gallery (enablePanicTitanGallery): settings-file symlink home
  galleryRuntimeDir = "${cfg.dataDir}/${cfg.panicTitanGallerySubdir}";

  # TokenSpender Sidebar Gallery (enableTokenSpenderSidebarGallery): its
  # three pack-root runtime items (settings json, cache.db, .thumbs) live here
  sidebarGalleryRuntimeDir = "${cfg.dataDir}/${cfg.tokenSpenderSidebarGallerySubdir}";
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

      # ComfyUI Prompt Manager: a CLIPTextEncode drop-in that auto-captures
      # every prompt it encodes into SQLite (sha256-deduped), links output
      # images via file monitoring, and serves an admin dashboard at
      # /prompt_manager/admin (search/ratings/tags/gallery/export);
      # PromptSearchList re-emits stored prompts as a list for batches.
      # Upstream defaults write into the pack directory (prompts.db,
      # config.json on settings saves, logs/ at import time, data/ for
      # LoRA-image import), which is a read-only store path here — so wrap
      # the fetch in runCommand and repoint all four:
      #   config.json — symlink to <subdir>/config.json, seeded once by a
      #     tmpfiles C rule; settings saves write *through* the symlink and
      #     survive restarts.
      #   logs / data — symlinks to <subdir>/<logs,data>, pre-created by
      #     tmpfiles because the rotating file handler opens at import.
      #   prompts.db — absolute path inside the seeded config.json; the
      #     pack creates parent dirs itself (operations.py makedirs).
      # Gallery thumbnails land in <outputDir>/thumbnails (writable), not
      # the pack. The LoRA Manager integration (off by default) reads LM's
      # .metadata.json files in memory and downloads Civitai previews into
      # data/lora_images via the symlink — its CivitAI key is typed once in
      # the Settings panel and now persists. AI AutoTag downloads WD14/
      # JoyCaption models on first use — untested on Nix, leave off.
      (lib.mkIf cfg.enableComfyAssetsPromptManager {
        prompt-manager = pkgs.runCommand "ComfyUI_PromptManager" {
          preferLocalBuild = true;
        } ''
          cp -r ${
            pkgs.fetchFromGitHub {
              owner = "ComfyAssets";
              repo = "ComfyUI_PromptManager";
              rev = "d70dab56e5fb67c3e471607bc10984975c4cc2aa";
              hash = "sha256-8XiFty1OQ0uP09PGQMuxkFg86aYWW/X6UkGwFWfKOD4=";
            }
          } $out
          chmod -R u+w $out  # fetchFromGitHub copies as read-only
          # Upstream _resolve_db_path (database/operations.py) imports
          # py.config absolutely, which sys.path-resolves against OTHER node
          # packs' py/ dirs (e.g. LoRA Manager loads first alphabetically)
          # and on failure silently falls back to a relative prompts.db
          # resolved against the extension root — i.e. through the
          # custom_nodes/ symlink into the READ-ONLY store: sqlite
          # CANTOPEN at import, API routes + image monitor never start.
          # Patch: prefer the correct relative-package import; env-var
          # fallback covers non-package module loading. Guarded by greps so
          # the build fails loudly if upstream changes the text.
          sed -i "s|from py.config import PromptManagerConfig|from ..py.config import PromptManagerConfig|" $out/database/operations.py
          sed -i "s|db_path = \"prompts.db\"|db_path = os.environ.get(\"PROMPT_MANAGER_DB_PATH\", \"prompts.db\")|" $out/database/operations.py
          grep -q "from ..py.config import PromptManagerConfig" $out/database/operations.py
          grep -q "os.environ.get(\"PROMPT_MANAGER_DB_PATH\"" $out/database/operations.py
          ln -s ${promptManagerRuntimeDir}/logs $out/logs
          ln -s ${promptManagerRuntimeDir}/config.json $out/config.json
          ln -s ${promptManagerRuntimeDir}/data $out/data
        '';
      })

      # PanicTitan ComfyUI-Gallery: real-time output gallery popup inside
      # the frontend (menu button / Ctrl+G) — folder tree, search/sort,
      # metadata inspect + raw JSON, move/delete/download/batch-ZIP, and
      # image/video/GIF/audio/3D support. Updates land via comfy's event
      # system + watchdog; scans folder_paths' output dir; serves media
      # read-only via a /static_gallery static route.
      # Nix treatment is lighter than PromptManager's: the ONLY pack-dir
      # write is user_settings.json, and only on settings SAVE (not at
      # import) — so the dangling symlink at load is harmless (defaults
      # used), and the first save lands in the tmpfiles-created runtime
      # dir, persisting across restarts. Audit found no other writes, so
      # no grep guards are needed here.
      # Upstream note: FileSystemMonitor constructs PollingObserver when
      # use_polling_observer is False (default) — the flag's naming is
      # inverted upstream, still functional (polling at 1s); report vs
      # patch.
      (lib.mkIf cfg.enablePanicTitanGallery {
        panictitan-gallery = pkgs.runCommand "ComfyUI-Gallery" {
          preferLocalBuild = true;
        } ''
          cp -r ${
            pkgs.fetchFromGitHub {
              owner = "PanicTitan";
              repo = "ComfyUI-Gallery";
              rev = "74639e68846f64c9f561f3a7745529de76376a97";
              hash = "sha256-8/pC0vF00JiKhublrXrGYdpL4dpOXK459inlHb/nZoA=";
            }
          } $out
          chmod -R u+w $out  # fetchFromGitHub copies as read-only
          ln -s ${galleryRuntimeDir}/user_settings.json $out/user_settings.json
        '';
      })

      # TokenSpender ComfyUI-Sidebar-Gallery: sidebar media browser with a
      # persistent SQLite index (sidebar_gallery_cache.db: file listing +
      # parsed metadata summaries; layouts/presets live server-side there
      # too, per-browser extras in localStorage) and a workflow-graph
      # metadata parser (resolves seed-from-primitive, pairs Wan 2.2 MoE
      # high/low passes, separates enhanced vs original prompts).
      # Audit found exactly three pack-root runtime writes, one of them a
      # load-killer:
      #   .thumbs/           — thumbnail cache; mkdir(exist_ok=True) at
      #                        routes.py import → EROFS on a store path →
      #                        symlink to a pre-created dir (tmpfiles)
      #   sidebar_gallery_config.json — settings save + manual extra_roots
      #                        edits (extra folders come ONLY from editing
      #                        this file); load uses path.exists() →
      #                        defaults, so a dangling link is harmless
      #   sidebar_gallery_cache.db    — created by sqlite on open; WAL
      #                        sidecars land beside it (contained in the
      #                        runtime dir)
      # Deps: av (PyAV) is imported lazily and guarded in routes.py/
      # metadata.py — it is ABSENT from the core env, so video/audio
      # metadata degrades silently without ps.av; we add it.
      (lib.mkIf cfg.enableTokenSpenderSidebarGallery {
        tokenspender-sidebar-gallery = pkgs.runCommand "ComfyUI-Sidebar-Gallery" {
          preferLocalBuild = true;
        } ''
          cp -r ${
            pkgs.fetchFromGitHub {
              owner = "TokenSpender";
              repo = "ComfyUI-Sidebar-Gallery";
              rev = "07e1d0e8b69f939ff52b964f812818b5ee6b7c96";
              hash = "sha256-HxvGBFB19ioZOujJ4Q6hUMEAwjDVV7iIKH94bQSkv74=";
            }
          } $out
          chmod -R u+w $out  # fetchFromGitHub copies as read-only
          ln -s ${sidebarGalleryRuntimeDir}/sidebar_gallery_config.json $out/sidebar_gallery_config.json
          ln -s ${sidebarGalleryRuntimeDir}/sidebar_gallery_cache.db $out/sidebar_gallery_cache.db
          ln -s ${sidebarGalleryRuntimeDir}/.thumbs $out/.thumbs
        '';
      })

      # Majoor Assets Manager: in-ComfyUI media library (Vue 3/TS UI) with
      # deep workflow inspection (Graph Map: readable subgraphs, node
      # detail/copy/import), Floating Viewer (live stream, A/B + side-by-
      # side + grid compare, KSampler/node streams), a workflow-tab
      # library (categories/tags/thumbnails), collections/tags/ratings,
      # and its own save nodes that embed generation_time_ms + prompt +
      # workflow into saved PNGs and MP4s (PyAV movflags) — which improves
      # video metadata indexing for every gallery here, not only its own.
      # NO wrapper: per its Data Locations table ALL runtime state is
      # <output>/_mjr_index/ (assets.sqlite, collections/, custom_roots)
      # + <output>/_mjr_batch_zips/; browser settings are localStorage —
      # zero pack-dir writes (the first pack in this stack needing only a
      # plain fetch). Optional exiftool/ffprobe are not in PATH: the
      # pure-python hachoir fallback covers audio/video probing.
      # Notes: the write-guard blocks writes when the UI is opened via a
      # LAN IP unless configured (Settings -> Security -> Recommended
      # Remote LAN Setup); the index artifacts inside output/ may be swept
      # by the other galleries' recursive scans (check after install);
      # AI/vector extras (requirements-vector.txt) intentionally not
      # installed.
      (lib.mkIf cfg.enableMajoorAssetsManager {
        majoor-assets = pkgs.fetchFromGitHub {
          owner = "MajoorWaldi";
          repo = "ComfyUI-Majoor-AssetsManager";
          rev = "3618a2048102e2c5818fa4d3497f8c3898664d5b";
          hash = "sha256-jiyYgSsD/yz3D+InybifumMkR0vDAsFSW7ahH/gQm6k=";
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
      ]
      # comfyassets-promptmanager: output file monitoring (Pillow already in core env)
      ++ lib.optional cfg.enableComfyAssetsPromptManager ps.watchdog
      # gallery: watchdog monitoring + piexif EXIF extraction (redundant
      # entries are deduped by the python env)
      ++ lib.optionals cfg.enablePanicTitanGallery [
        ps.watchdog
        ps.piexif
      ]
      # sidebar-gallery: video/audio container metadata via PyAV (lazy-
      # imported; absent from core env otherwise)
      ++ lib.optionals cfg.enableTokenSpenderSidebarGallery [
        ps.av
      ]
      # majoor-assets: deps listed here so the pack stays independent of
      # other packs' toggles (av/aiosqlite/watchdog overlap them but are
      # deduped); hachoir = pure-python probe fallback for missing
      # exiftool/ffprobe; blake3 = core asset-id hashing
      ++ lib.optionals cfg.enableMajoorAssetsManager [
        ps.av
        ps.aiosqlite
        ps.watchdog
        ps.hachoir
        ps.send2trash
        ps.blake3
      ];

    # Point the pack's stored-key path at the agenix-decrypted file when
    # provided — its reads treat the file's contents as the API key, so the
    # interactive sidebar sign-in is never needed.
    environment = lib.mkMerge [
      (lib.mkIf (cfg.enableCivitaiNodes && cfg.civitaiApiKeyFile != null) {
        CIVITAI_COMFY_API_KEY_STORE = cfg.civitaiApiKeyFile;
      })
      (lib.mkIf cfg.enableComfyAssetsPromptManager {
        # DB-path fallback for prompt-manager (see the customNodes entry:
        # upstream's absolute py.config import can bind a foreign pack's
        # py/ and silently fall back to the store path).
        PROMPT_MANAGER_DB_PATH = "${promptManagerRuntimeDir}/prompts.db";
      })
    ];
  };

  # Runtime dirs (see the customNodes entries): tmpfiles completes before
  # the service starts, so every pack's symlink targets and import-time
  # writes find writable paths. PM's C rule seeds config.json only when
  # missing — settings saved through the pack-side symlink survive
  # reboots. The gallery has no seed on purpose: its dangling
  # user_settings.json link reads as {} defaults until the first settings
  # save lands through it.
  systemd.tmpfiles.rules = lib.concatLists [
    (lib.optionals cfg.enableComfyAssetsPromptManager [
      "d ${promptManagerRuntimeDir} 0755 ${cfg.user} ${cfg.group} -"
      "d ${promptManagerRuntimeDir}/logs 0755 ${cfg.user} ${cfg.group} -"
      "d ${promptManagerRuntimeDir}/data 0755 ${cfg.user} ${cfg.group} -"
      "C ${promptManagerRuntimeDir}/config.json 0644 ${cfg.user} ${cfg.group} - ${promptManagerConfigSeed}"
    ])
    (lib.optionals cfg.enablePanicTitanGallery [
      "d ${galleryRuntimeDir} 0755 ${cfg.user} ${cfg.group} -"
    ])
    (lib.optionals cfg.enableTokenSpenderSidebarGallery [
      "d ${sidebarGalleryRuntimeDir} 0755 ${cfg.user} ${cfg.group} -"
      "d ${sidebarGalleryRuntimeDir}/.thumbs 0755 ${cfg.user} ${cfg.group} -"
    ])
  ];
}
