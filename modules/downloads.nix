# Download fetching: multi-GB model files and other artifacts (workflows,
# pose packs, ...) stay out of the nix store. `mkDownloadService` builds a
# oneshot systemd service from cfg.comfyui.downloads — an attrset of
# { path-relative-to-dataDir -> entry } — fetching anything missing before
# the ComfyUI service starts. Entries tagged source = "huggingface"
# (built by hfFetch in ./sources.nix) download with the hf CLI — native xet
# transport, gated-repo auth — and fall back to the resolve URL over curl;
# civitai-tagged entries (civitaiFetch) download through the official
# civitai CLI when the consumer threads it via specialArgs, with the
# download endpoint over resumable curl as fallback; everything else
# fetches with resumable curl. Build entries with the constructors in
# ./sources.nix (they pin the revision and inject the right token per
# source); every entry's pinned sha256 gates the result regardless of
# transport.
{
  config,
  pkgs,
  lib,
  civitai-cli ? null,
  ...
}:
let
  cfg = config.cfg.comfyui;

  # HuggingFace-sourced entries download with the hf CLI (native xet
  # transport for xet-backed repos, gated-repo auth). The python env only
  # enters the closure when at least one such entry exists, so
  # civitai/direct-URL-only consumers don't pay for it.
  hasHfDownloads = lib.any (dl: dl.source or null == "huggingface") (
    lib.attrValues cfg.downloads
  );
  hfEnv = pkgs.python3.withPackages (ps: [
    ps.huggingface-hub
    ps.hf-xet
  ]);

  # CivitAI CLI (github:civitai/cli) — the transport for source = "civitai"
  # entries when the consumer threads the flake via specialArgs, mirroring
  # the hf CLI pattern (CLI first, resumable curl fallback). Without the
  # flake input, civitai entries keep the plain-curl behavior.
  hasCivitaiDownloads = lib.any (dl: dl.source or null == "civitai") (
    lib.attrValues cfg.downloads
  );
  civitaiCliPkg =
    if civitai-cli != null
    then civitai-cli.packages.${pkgs.system}.default or null
    else null;

  # Build the oneshot service that fetches `downloads` into `dataDir`
  # before `target`'s service starts. Idempotent: existing files are never
  # touched; each entry tries its URL then fallbackUrls in order (so an
  # entry survives its source repo removing the file — just add a mirror);
  # finished downloads are verified against sha256 when the entry provides
  # one.
  mkDownloadService = {
    dataDir,
    user,
    downloads,
    mountUnits ? [ ],
    target ? "comfyui",
  }: {
    systemd.services."${target}-download-fetch" = {
      description = "Fetch ComfyUI downloads";
      before = [ "${target}.service" ];
      requiredBy = [ "${target}.service" ];
      after = mountUnits;
      requires = mountUnits;
      serviceConfig = {
        Type = "oneshot";
        User = user;
        TimeoutStartSec = 0;
      };
      script = ''
        set -euo pipefail
        export PATH=${pkgs.coreutils}/bin${lib.optionalString hasHfDownloads ":${hfEnv}/bin"}${lib.optionalString (hasCivitaiDownloads && civitaiCliPkg != null) ":${civitaiCliPkg}/bin"}
        ${lib.optionalString hasHfDownloads ''
          export HF_HOME="${dataDir}/.hf-home"
          export HF_HUB_DISABLE_TELEMETRY=1
        ''}
        # verify_or_move <dest> <sha256> — hash-check the staged download and
        # move it into place; loud failure otherwise.
        verify_or_move() {
          local dest="$1" hash="$2"
          if [[ -z "$hash" ]] || echo "$hash  $dest.part" | ${pkgs.coreutils}/bin/sha256sum --check --quiet; then
            mv "$dest.part" "$dest"
            return 0
          fi
          echo "sha256 mismatch for $dest" >&2
          rm -f "$dest.part"
          return 1
        }
        # unzip_into <archive> <into-dir> <sha256|empty> — extract once per
        # archive hash, then self-verify: at extraction time the tree is
        # checksum-manifested against the zip's own file list (the archive
        # was sha256-gated before landing, so the manifest pins verified
        # content). Later boots recheck the manifest; drift (in-place edits
        # or deletions) is repaired by re-extracting. Delete the marker
        # files to force a full re-extract.
        unzip_into() {
          local archive="$1" into="$2" hash="$3"
          # resolve against the caller's cwd (dataDir) up front — later
          # steps cd into the target dir, which would break relative paths
          archive="$(${pkgs.coreutils}/bin/readlink -m "$archive")"
          if [[ ! -e "$archive" ]]; then
            echo "archive missing: $archive" >&2
            return 1
          fi
          # AppleDouble junk from macOS-created zips — prune on every pass
          # so both fresh extractions and stale copies stay clean
          ${pkgs.coreutils}/bin/rm -rf "$into/__MACOSX"
          local stamp="$into/.unzipped"
          local want="''${hash:-none}"
          if [[ -e "$stamp" ]] && [[ "$(cat "$stamp")" == "$want" ]]; then
            # an empty manifest (e.g. left by a half-finished earlier run)
            # must count as drift, not as a passing verification
            if ( cd "$into" && [[ -s ".unzipped.sha256" ]] \
              && ${pkgs.coreutils}/bin/sha256sum --quiet -c ".unzipped.sha256" ); then
              echo "verified: $archive"
              return 0
            fi
            echo "extracted tree drifted — re-extracting from $archive" >&2
          fi
          mkdir -p "$into"
          ${pkgs.unzip}/bin/unzip -o "$archive" -d "$into"
          ${pkgs.coreutils}/bin/rm -rf "$into/__MACOSX"
          printf '%s\n' "$want" > "$stamp"
          ( cd "$into" \
            && ${pkgs.unzip}/bin/unzip -Z1 "$archive" \
            | ${pkgs.gnugrep}/bin/grep -v -e '/$' -e '^__MACOSX/' \
            | ${pkgs.coreutils}/bin/sort \
            | ${pkgs.findutils}/bin/xargs -r -d '\n' ${pkgs.coreutils}/bin/sha256sum -- \
            > ".unzipped.sha256" )
        }
        # fetch_one <dest> <sha256|empty> <tokenFile|empty> <url> [fallback-url...]
        # Tries each URL in order; resumes partial downloads (`curl -C -`).
        # A token, when present, is passed to curl via stdin config (-K -) so
        # it never appears in process arguments (visible through
        # /proc/<pid>/cmdline otherwise).
        fetch_one() {
          local dest="$1" hash="$2" token_file="$3"
          shift 3
          if [[ -e "$dest" ]]; then
            echo "have: $dest"
            return 0
          fi
          mkdir -p "$(dirname "$dest")"
          local url ok
          for url in "$@"; do
            echo "fetching: $dest"
            ok=1
            if [[ -n "$token_file" ]]; then
              if printf 'header = "Authorization: Bearer %s"\n' "$(<"$token_file")" \
                | ${pkgs.curl}/bin/curl -K - -L --fail --retry 3 -C - "$url" -o "$dest.part"; then
                ok=0
              fi
            else
              if ${pkgs.curl}/bin/curl -L --fail --retry 3 -C - "$url" -o "$dest.part"; then
                ok=0
              fi
            fi
            if [[ $ok -eq 0 ]] && verify_or_move "$dest" "$hash"; then
              return 0
            fi
            rm -f "$dest.part"
          done
          echo "all sources failed for: $dest" >&2
          return 1
        }
        # verify_in_place <dest> <sha256> — hash-check a file downloaded in
        # place (the CLI's own rename already made it atomic).
        verify_in_place() {
          local dest="$1" hash="$2"
          if [[ -z "$hash" ]] || echo "$hash  $dest" | ${pkgs.coreutils}/bin/sha256sum --check --quiet; then
            return 0
          fi
          echo "sha256 mismatch for $dest" >&2
          rm -f "$dest"
          return 1
        }
        # fetch_civitai <dest> <sha256|empty> <tokenFile|empty> <versionId>
        #           [file|empty] — civitai CLI transport: streams to
        # <target>.part and renames into place on success while verifying
        # the server's own SHA256; the entry's pinned hash then gates the
        # final file (authoritative — the API hash can drift when an author
        # re-uploads inside a version). --file picks a specific file in a
        # multi-file version. On CLI failure falls back to the download
        # endpoint over resumable curl (primary-file downloads only — a
        # --file request has no curl equivalent).
        fetch_civitai() {
          local dest="$1" hash="$2" token_file="$3" version_id="$4" file="''${5:-}"
          if [[ -e "$dest" ]]; then
            echo "have: $dest"
            return 0
          fi
          mkdir -p "$(dirname "$dest")"
          echo "fetching (civitai): $dest"
          local -a dl_args=(--version "$version_id" --out "$dest")
          [[ -n "$file" ]] && dl_args+=(--file "$file")
          local cli_ok=1
          if CIVITAI_TOKEN="$(cat "$token_file")" CIVITAI_NO_UPDATE_CHECK=1 \
            ${civitaiCliPkg}/bin/civitai download "''${dl_args[@]}"; then
            cli_ok=0
          fi
          if [[ $cli_ok -eq 0 ]] && verify_in_place "$dest" "$hash"; then
            return 0
          fi
          rm -f "$dest"
          if [[ -z "$file" ]] && fetch_one "$dest" "$hash" "$token_file" "https://civitai.com/api/download/models/$version_id" "$@"; then
            return 0
          fi
          return 1
        }
        # fetch_hf <dest> <sha256|empty> <tokenFile|empty> <repo> <rev> <file>
        #           [fallback-url...] — HuggingFace transport via the hf CLI
        # (native xet chunks, gated-repo auth via HF_TOKEN). Downloads into a
        # hidden per-dest staging dir — hf's resume metadata lives inside it,
        # so the model tree never sees it — hash-gates, then installs
        # atomically. On hf failure falls back to the resolve URL over curl
        # (then any fallback urls); a staging dir left by a killed run is
        # hf's resume state and the next run picks it back up.
        fetch_hf() {
          local dest="$1" hash="$2" token_file="$3" repo="$4" rev="$5" file="$6"
          shift 6
          if [[ -e "$dest" ]]; then
            echo "have: $dest"
            return 0
          fi
          mkdir -p "$(dirname "$dest")"
          local stage="$(dirname "$dest")/.$(basename "$dest").hfpart"
          echo "fetching (hf): $dest"
          local hf_ok=1 verified=0
          if [[ -n "$token_file" ]]; then
            if HF_TOKEN="$(cat "$token_file")" hf download "$repo" "$file" --revision "$rev" --local-dir "$stage" -q; then
              hf_ok=0
            fi
          else
            if hf download "$repo" "$file" --revision "$rev" --local-dir "$stage" -q; then
              hf_ok=0
            fi
          fi
          if [[ -z "$hash" ]] || echo "$hash  $stage/$file" | ${pkgs.coreutils}/bin/sha256sum --check --quiet; then
            verified=1
          fi
          if [[ $hf_ok -eq 0 && $verified -eq 1 ]]; then
            ${pkgs.coreutils}/bin/install -D -m 0644 "$stage/$file" "$dest"
            rm -rf "$stage"
            return 0
          fi
          if [[ $hf_ok -eq 0 ]]; then
            echo "sha256 mismatch for $dest" >&2
          fi
          rm -rf "$stage"
          if fetch_one "$dest" "$hash" "$token_file" "https://huggingface.co/$repo/resolve/$rev/$file" "$@"; then
            return 0
          fi
          # fetch_one already reported "all sources failed".
          return 1
        }
        cd ${dataDir}
        ${lib.concatStringsSep "\n" (
          let
            entries = lib.mapAttrsToList (
              dest: dl:
              let
                hash = if dl.sha256 != null then dl.sha256 else "";
                tokenFile = if dl.tokenFile != null then dl.tokenFile else "";
                esc = lib.escapeShellArg;
                isHf = dl.source or null == "huggingface";
                isCivitai = dl.source or null == "civitai";
                fetchLine =
                  if isHf then
                    # The hf CLI is the transport; the resolve URL is
                    # reconstructed inside fetch_hf as the first curl
                    # fallback, so only extra mirrors are passed here.
                    ''fetch_hf ${esc dest} ${esc hash} ${esc tokenFile} ${esc dl.repo} ${esc dl.rev} ${esc dl.file} ${lib.concatMapStringsSep " " esc dl.fallbackUrls}''
                  else if isCivitai && civitaiCliPkg != null then
                    # The CLI transport; the download endpoint is
                    # reconstructed inside fetch_civitai as the curl
                    # fallback, so only extra mirrors are passed here.
                    let
                      civArgs =
                        [ "fetch_civitai" dest hash tokenFile dl.versionId (if dl.file != null then dl.file else "") ]
                        ++ dl.fallbackUrls;
                    in
                    lib.concatMapStringsSep " " esc civArgs
                  else
                    let
                      urls = [ dl.url ] ++ dl.fallbackUrls;
                    in
                    ''fetch_one ${esc dest} ${esc hash} ${esc tokenFile} ${lib.concatMapStringsSep " " esc urls}'';
              in
              {
                fetch = [ fetchLine ];
                unzip = lib.optional (dl.unzipInto != null) ''unzip_into ${esc dest} ${esc dl.unzipInto} ${esc hash}'';
              }
            ) downloads;
          in
          lib.concatLists (map (e: e.fetch) entries)
          ++ lib.concatLists (map (e: e.unzip) entries)
        )}
      '';
    };
  };
in
{
  # Instantiated unconditionally: with an empty list the generated script is
  # a no-op. The download list itself is consumer data
  # (cfg.comfyui.downloads).
  config = mkDownloadService {
    inherit (cfg) dataDir user downloads;
    mountUnits = cfg.requiresMounts;
  };
}