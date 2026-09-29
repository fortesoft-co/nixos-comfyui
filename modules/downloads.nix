# Download fetching: multi-GB model files and other artifacts (workflows,
# pose packs, ...) stay out of the nix store. `mkDownloadService` builds
# oneshot services from cfg.comfyui.downloads — an attrset of
# { id-or-legacy-path -> entry } — fetching anything missing before the
# ComfyUI service starts.
#
# Destinations: entries are either path-keyed (attrset key = dataDir-relative
# path, the legacy form) or structured — an id-keyed entry setting
# `type` (a ComfyUI models/ subdir) + `name` (+ optional `arch` subpath
# segment(s), e.g. arch = "wan" or ["WanVideo" "Lightx2v"]) composes
# models/<type>/<arch>/<name>. Non-model entries (user/default/workflows/...)
# set `dest` directly. Derived destinations are asserted unique at eval.
#
# Enforcement (enforcePaths): the fetch unit runs a stat-cheap pin pass
# before fetching — a pinned file that went missing is restored from a
# stray copy on the same filesystem (size + sha256 verified, and moving on
# a single pool is an atomic rename) rather than re-fetched; a pinned file
# whose size changed versus its manifest is repaired (impostor moved aside
# → refetch → impostor freed only after the replacement is hash-verified).
# Entries with a sha256 pin are rescue-eligible; unpinned entries get a
# presence-only pass.
#
# auditSchedule adds <target>-download-audit.service/.timer: a scheduled
# full sha256 sweep over pinned entries (mtime+size manifest-skipped, so
# unchanged content costs syscalls and nothing more) with the same repair
# semantics — size-equal hash mismatches are invisible to the cheap pass
# and only this sweep catches them. Repair never destroys local bytes
# until the refetch's replacement is hash-verified in staging; when the
# upstream is gone the impostor stays in place and the unit fails loudly.
#
# Transports: entries tagged source = "huggingface" (built by hfFetch in
# ./sources.nix) download with the hf CLI — native xet transport, gated-repo
# auth — and fall back to the resolve URL over curl; civitai-tagged entries
# (civitaiFetch) download through the official civitai CLI when the consumer
# threads it via specialArgs, with the download endpoint over resumable curl
# as fallback; everything else fetches with resumable curl. Entries pin the
# revision via the ./sources.nix constructors and gate the result against
# sha256 regardless of transport.
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

  mkDownloadService =
    {
      dataDir,
      user,
      downloads,
      enforce ? true,
      auditSchedule ? null,
      mountUnits ? [ ],
      target ? "comfyui",
    }:
    let
      # Destination resolution. Exactly one of:
      #   - explicit dest (non-model entries),
      #   - structured: models/<type>/<arch segments>/<name>,
      #   - legacy: the attrset key itself is a dataDir-relative path.
      segOk =
        s: s != "" && s != "." && !lib.hasInfix "/" s && !lib.hasInfix ".." s;
      destOf =
        key: dl:
        if dl.dest != null then
          if dl.type != null then
            throw "downloads[\"${key}\"]: set either dest or type, not both"
          else dl.dest
        else if dl.type != null then
          if dl.name == null then
            throw "downloads[\"${key}\"]: structured entry (type set) needs a name"
          else if !lib.all segOk ([ dl.type ] ++ dl.arch ++ [ dl.name ]) then
            throw "downloads[\"${key}\"]: type/arch/name must be single path segments"
          else lib.concatStringsSep "/" ([ "models" dl.type ] ++ dl.arch ++ [ dl.name ])
        else if !lib.hasInfix "/" key then
          throw "downloads[\"${key}\"]: id-keyed entries need a type+name or a dest"
        else
          # legacy: the attrset key is the dataDir-relative destination
          key;

      hashOf = dl: if dl.sha256 != null then dl.sha256 else "";
      tokenOf = dl: if dl.tokenFile != null then dl.tokenFile else "";

      entries = lib.mapAttrsToList (
        key: dl:
        let
          esc = lib.escapeShellArg;
          dest = destOf key dl;
          hash = hashOf dl;
          tokenFile = tokenOf dl;
          isHf = dl.source or null == "huggingface";
          isCivitai = dl.source or null == "civitai";
          fetchArgs =
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
                civArgs = [
                  "fetch_civitai"
                  dest
                  hash
                  tokenFile
                  dl.versionId
                  (if dl.file != null then dl.file else "")
                ] ++ dl.fallbackUrls;
              in
              lib.concatMapStringsSep " " esc civArgs
            else
              let
                urls = [ dl.url ] ++ dl.fallbackUrls;
              in
              ''fetch_one ${esc dest} ${esc hash} ${esc tokenFile} ${lib.concatMapStringsSep " " esc urls}'';
          unzip = lib.optional (dl.unzipInto != null) ''unzip_into ${esc dest} ${esc dl.unzipInto} ${esc hash}'';
        in
        { inherit dest hash fetchArgs unzip esc key; }
      ) downloads;

      indexed = lib.imap1 (i: e: e // { n = toString i; }) entries;

      destsList = map (e: e.dest) entries;
      dupDests = lib.filter (d: lib.length (lib.filter (x: x == d) destsList) > 1) (lib.unique destsList);
      uniqueDestAssertion = {
        assertion = dupDests == [ ];
        message =
          "comfyui downloads: duplicate destinations (${lib.concatStringsSep ", " dupDests}) — every entry must resolve to a distinct file";
      };

      fetchScript = pkgs.writeShellScript "${target}-download-fetch" ''
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

        # ----------------------------------------------------------------------
        # Pin enforcement. Nothing local is ever destroyed until its
        # replacement is hash-verified on disk; upstream death leaves the
        # local bytes in place and fails loudly.
        # ----------------------------------------------------------------------
        cd ${dataDir}
        # dest \t size \t mtime(epoch secs) \t sha256 — written after every
        # verified fetch/repair; audit runs skip hashing unchanged rows.
        PINS_MANIFEST=".pins.sha256.tsv"

        file_sha() {
          local p="$1"
          ${pkgs.coreutils}/bin/sha256sum "$p" | ${pkgs.coreutils}/bin/cut -d' ' -f1
        }

        # manifest_row <dest> -> "<size>\t<mtime>\t<sha256>" or empty
        manifest_row() {
          local dest="$1"
          [[ -f "$PINS_MANIFEST" ]] || return 0
          ${pkgs.gawk}/bin/awk -F'\t' -v d="$dest" '$1 == d { print $2 "\t" $3 "\t" $4; exit }' "$PINS_MANIFEST"
        }

        # manifest_set <dest> <size> <mtime> <sha256|empty>
        manifest_set() {
          local dest="$1" size="$2" mtime="$3" sha="$4"
          local tmp="$PINS_MANIFEST.tmp"
          if [[ -f "$PINS_MANIFEST" ]]; then
            ${pkgs.gawk}/bin/awk -F'\t' -v d="$dest" '$1 != d' "$PINS_MANIFEST" > "$tmp"
          else
            : > "$tmp"
          fi
          printf '%s\t%s\t%s\t%s\n' "$dest" "$size" "$mtime" "$sha" >> "$tmp"
          mv -f "$tmp" "$PINS_MANIFEST"
        }

        # stray_find <sha256> <expected-size|empty> — print the first path
        # under models/ whose bytes hash to <sha256>, else fail. When a
        # verified size is known it pre-filters candidates (an external move
        # never changes a file's size), so the common repair hashes exactly
        # one candidate file; without it (first run / no manifest) the whole
        # models/ tree is hashed. Hidden entries are pruned — staging
        # (.hfpart dirs), drift leftovers and .part temporaries never count
        # as strays.
        stray_find() {
          local sha="$1" want_size="''${2:-}"
          [[ -d models ]] || return 1
          local -a size_args=( )
          if [[ -n "$want_size" ]]; then
            size_args=( -size "''${want_size}c" )
          fi
          local cand h
          while IFS= read -r -d "" cand; do
            h="$(file_sha "$cand")"
            if [[ "$h" == "$sha" ]]; then
              printf '%s' "$cand"
              return 0
            fi
          done < <( ${pkgs.findutils}/bin/find models \( -name '.*' -prune \) -o -type f "''${size_args[@]}" -not -name '*.part' -print0 )
          return 1
        }

        # rescue_or_fetch <dest> <sha256|empty> <entry-fn> — when the
        # destination is gone: restore a stray copy if the pinned bytes can
        # be found elsewhere, otherwise run the entry's transport (which
        # stages, hash-gates and installs atomically).
        rescue_or_fetch() {
          local dest="$1" sha="$2" entry_fn="$3"
          if [[ -n "$sha" ]]; then
            local row want_size=""
            row="$(manifest_row "$dest")"
            if [[ -n "$row" ]]; then
              want_size="$(printf '%s' "$row" | ${pkgs.coreutils}/bin/cut -f1)"
            fi
            local stray
            if stray="$(stray_find "$sha" "$want_size")"; then
              echo "restoring stray: $stray -> $dest"
              mkdir -p "$(dirname "$dest")"
              mv -f "$stray" "$dest"
              manifest_set "$dest" "$(${pkgs.coreutils}/bin/stat -c '%s' "$dest")" "$(${pkgs.coreutils}/bin/stat -c '%Y' "$dest")" "$sha"
              return 0
            fi
          fi
          echo "missing: $dest" >&2
          "$entry_fn" || return 1
          manifest_set "$dest" "$(${pkgs.coreutils}/bin/stat -c '%s' "$dest")" "$(${pkgs.coreutils}/bin/stat -c '%Y' "$dest")" "$sha"
          echo "fetched: $dest"
          return 0
        }

        # repair <dest> <sha256> <entry-fn> — destination currently holds
        # bytes that don't match the pin. The impostor moves to a hidden
        # sibling (same-filesystem rename), the entry refetches into the
        # verified staging path, and the impostor is freed only after the
        # replacement is verified on disk — its journal line records size
        # and hash, so nothing is lost silently. A failed fetch restores
        # the impostor in place (never destroy the only copy when upstream
        # is unreachable) and fails the entry.
        repair() {
          local dest="$1" sha="$2" entry_fn="$3"
          local dir base drift
          dir="$(dirname "$dest")"
          base="$(basename "$dest")"
          drift="$dir/.$base.drift"
          mkdir -p "$dir"
          mv -f "$dest" "$drift"
          if "$entry_fn"; then
            echo "repair: freeing impostor $(file_sha "$drift") $drift" >&2
            rm -f "$drift"
            manifest_set "$dest" "$(${pkgs.coreutils}/bin/stat -c '%s' "$dest")" "$(${pkgs.coreutils}/bin/stat -c '%Y' "$dest")" "$sha"
            return 0
          fi
          mv -f "$drift" "$dest"
          echo "repair failed for $dest — impostor restored in place" >&2
          return 1
        }

        # recover drift siblings left by an interrupted repair: back to the
        # destination when it never landed, discardable when it did.
        recover_drift() {
          local dest="$1"
          local drift="$(dirname "$dest")/.$(basename "$dest").drift"
          if [[ ! -e "$dest" && -e "$drift" ]]; then
            echo "recovering leftover drift: $drift -> $dest"
            mv -f "$drift" "$dest"
          elif [[ -e "$dest" && -e "$drift" ]]; then
            rm -f "$drift"
          fi
        }

        # ensure <dest> <sha256|empty> <entry-fn> — boot-time pin pass:
        # stat-cheap. Missing pins are rescued or fetched; present pins are
        # trusted unless the verified manifest says their size changed.
        ensure() {
          local dest="$1" sha="$2" entry_fn="$3"
          recover_drift "$dest"
          if [[ ! -e "$dest" ]]; then
            rescue_or_fetch "$dest" "$sha" "$entry_fn" || return 1
            return 0
          fi
          local row dsize
          row="$(manifest_row "$dest")"
          dsize="$(${pkgs.coreutils}/bin/stat -c '%s' "$dest")"
          if [[ -n "$row" ]]; then
            local msize
            msize="$(printf '%s' "$row" | ${pkgs.coreutils}/bin/cut -f1)"
            if [[ "$msize" != "$dsize" ]]; then
              echo "size drift at $dest ($msize -> $dsize)" >&2
              if [[ -z "$sha" ]]; then
                # presence-only entry: nothing verifiable, just restamp
                manifest_set "$dest" "$dsize" "$(${pkgs.coreutils}/bin/stat -c '%Y' "$dest")" ""
                return 0
              fi
              repair "$dest" "$sha" "$entry_fn" || return 1
              return 0
            fi
          fi
          echo "have: $dest"
          return 0
        }

        # audit_entry <dest> <sha256|empty> <entry-fn> — scheduled deep
        # verification. Skips hashing when mtime+size match the verified
        # manifest row (same-second replacement of equal-size bytes is the
        # accepted blind spot; run audit after staging anything manually).
        audit_entry() {
          local dest="$1" sha="$2" entry_fn="$3"
          recover_drift "$dest"
          if [[ ! -e "$dest" ]]; then
            rescue_or_fetch "$dest" "$sha" "$entry_fn" || return 1
            return 0
          fi
          local dsize dmt
          dsize="$(${pkgs.coreutils}/bin/stat -c '%s' "$dest")"
          dmt="$(${pkgs.coreutils}/bin/stat -c '%Y' "$dest")"
          local row
          row="$(manifest_row "$dest")"
          if [[ -n "$row" ]]; then
            local msize mmt msha
            msize="$(printf '%s' "$row" | ${pkgs.coreutils}/bin/cut -f1)"
            mmt="$(printf '%s' "$row" | ${pkgs.coreutils}/bin/cut -f2)"
            msha="$(printf '%s' "$row" | ${pkgs.coreutils}/bin/cut -f3)"
            if [[ "$msize" == "$dsize" && "$mmt" == "$dmt" ]]; then
              if [[ -z "$sha" || "$msha" == "$sha" ]]; then
                echo "verified (unchanged): $dest"
                return 0
              fi
            fi
          fi
          if [[ -z "$sha" ]]; then
            manifest_set "$dest" "$dsize" "$dmt" ""
            echo "no sha256 pin — presence recorded: $dest"
            return 0
          fi
          local h
          h="$(file_sha "$dest")"
          if [[ "$h" != "$sha" ]]; then
            echo "sha256 mismatch: $dest (have $h, want $sha)" >&2
            repair "$dest" "$sha" "$entry_fn" || return 1
            return 0
          fi
          manifest_set "$dest" "$dsize" "$dmt" "$sha"
          echo "verified: $dest"
          return 0
        }

        MODE="''${1:-fetch}"
        case "$MODE" in
          fetch)
            ${
              if enforce then
                lib.concatMapStringsSep "\n" (
                  e: ''ensure ${lib.escapeShellArg e.dest} ${lib.escapeShellArg e.hash} entry_${e.n}''
                ) indexed
              else
                # unenforced: pure fetch (legacy semantics — entry functions
                # early-return on files that already exist)
                lib.concatMapStringsSep "\n" (e: e.fetchArgs) indexed
            }
            ${lib.concatStringsSep "\n" (lib.concatLists (map (e: e.unzip) entries))}
            ;;
          audit)
            failed=0
            ${lib.concatMapStringsSep "\n" (
              e: ''if ! audit_entry ${lib.escapeShellArg e.dest} ${lib.escapeShellArg e.hash} entry_${e.n}; then echo "audit failed: ${lib.escapeShellArg e.dest}" >&2; failed=1; fi''
            ) indexed}
            if [[ "$failed" -ne 0 ]]; then
              echo "download-audit: entries failed (see above)" >&2
              exit 1
            fi
            ;;
          *)
            echo "usage: $(basename "$0") [fetch|audit]" >&2
            exit 2
            ;;
        esac
      '';
    in
    # Entry transports are emitted as numbered bash functions so the
    # boot (ensure) and audit (repair) passes can re-run the exact same
    # fetch for a pin regardless of transport. The audit unit is declared
    # unconditionally (shape stays config-independent — an optionalAttrs
    # here would recurse into the fixpoint during the module merge); its
    # body is gated lazily by mkIf on the schedule.
    {
      assertions = [ uniqueDestAssertion ];
      systemd.services = {
        "${target}-download-fetch" = {
          description = "Fetch ComfyUI downloads";
          before = [ "${target}.service" ];
          requiredBy = [ "${target}.service" ];
          after = mountUnits;
          requires = mountUnits;
          serviceConfig = {
            Type = "oneshot";
            User = user;
            TimeoutStartSec = 0;
            ExecStart = "${fetchScript} fetch";
          };
        };
        "${target}-download-audit" = lib.mkIf (auditSchedule != null) {
          description = "Verify ComfyUI pinned downloads (sha256 sweep + repair)";
          # never race the boot fetcher over staging areas
          after = mountUnits ++ [ "${target}-download-fetch.service" ];
          requires = mountUnits;
          conflicts = [ "${target}-download-fetch.service" ];
          serviceConfig = {
            Type = "oneshot";
            User = user;
            TimeoutStartSec = 0;
            ExecStart = "${fetchScript} audit";
          };
        };
      };
      systemd.timers = lib.mkIf (auditSchedule != null) {
        "${target}-download-audit" = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = auditSchedule;
            Persistent = true;
            Unit = "${target}-download-audit.service";
          };
        };
      };
    };
in
{
  # Instantiated unconditionally: with an empty list the generated script is
  # a no-op. The download list itself is consumer data
  # (cfg.comfyui.downloads).
  config = mkDownloadService {
    inherit (cfg) dataDir user downloads;
    enforce = cfg.enforcePaths;
    auditSchedule = cfg.auditSchedule;
    mountUnits = cfg.requiresMounts;
  };
}