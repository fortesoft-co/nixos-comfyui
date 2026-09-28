# Comfy MCP — official MCP server from Comfy Org (Comfy-Org/comfy-mcp).
#
# A stdio MCP server: the client (Zed, Claude Code, ...) spawns it as a
# subprocess, and its tools drive the running ComfyUI — this module's systemd
# service — over HTTP on 127.0.0.1 (the configured port). The server is a thin wrapper that
# shells out to comfy-cli, so both are packaged here into one interpreter env.
#
# Every version below is pinned by hash and locked by the flake: no runtime
# pip installs anywhere in this chain. The mcp SDK 2.x and mcp-types are
# pinned here (not from nixpkgs) because the locked nixpkgs still ships the
# SDK at 1.x, while comfy-mcp imports `mcp.server.mcpserver`, which exists
# only in 2.x. A standalone env also keeps the ComfyUI service dependency
# set untouched.
#
# Two nixpkgs deps miss comfy-cli's declared version ranges without mattering
# at runtime: mixpanel 5.0.0 (wants <5; that pin only avoids a pydantic clash
# inside ComfyUI's env, which this one is not) and blake3 1.0.8 (wants
# >=1.0.9).
#
# Lifecycle note: comfy-cli's install/update/stop verbs assume it owns a
# ComfyUI checkout, so with the Nix-managed service stick to the HTTP tools
# (run_workflow, generate_image, run_template, job, fetch_outputs, ...) and
# manage the service itself with systemctl. Never pre-authorize its
# `kill_untracked` consent: the "untracked server" on :8188 is ours.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  # Scoped package set for the MCP tools. The locked nixpkgs' inline-snapshot
  # test suite is broken (snapshot teardown error) and the package is only
  # ever a check input, so its checks are skipped here — which unblocks the
  # anthropic -> fastapi -> posthog chain that comfy-cli's analytics dep
  # requires. The override is scoped to this env; nothing else in the system
  # changes.
  py = (pkgs.python312.override {
    packageOverrides = _: super: {
      inline-snapshot = super.inline-snapshot.overridePythonAttrs (_: {
        doCheck = false;
      });
    };
  }).pkgs;

  mcpTypes = py.buildPythonPackage rec {
    pname = "mcp-types";
    version = "2.2.0";
    format = "wheel";
    src = pkgs.fetchurl {
      url = "https://files.pythonhosted.org/packages/8f/d7/6ffba5d8cd5dd9b8a19478875c50e04945314ba5074e84d749283f27f62d/mcp_types-2.2.0-py3-none-any.whl";
      hash = "sha256-6kdrc+6GcJq1q8lFI4XtNswFkH5YI1ViLilFlcmgTxM=";
    };
    dependencies = with py; [
      pydantic
      typing-extensions
    ];
    meta = {
      description = "Wire types for the Model Context Protocol SDK 2.x";
      homepage = "https://github.com/modelcontextprotocol/python-sdk";
      license = lib.licenses.mit;
      sourceProvenance = with lib.sourceTypes; [ binaryWheel ];
    };
  };

  mcpSdk = py.buildPythonPackage rec {
    pname = "mcp";
    version = "2.2.0";
    format = "wheel";
    src = pkgs.fetchurl {
      url = "https://files.pythonhosted.org/packages/1b/ff/8e7eade68b8a28f7da0ed1085544341b51f9c935dbf6b95c76b7edfea6a0/mcp-2.2.0-py3-none-any.whl";
      hash = "sha256-vemCWJRzoGCuFF40BumlMz/lOMlyKbqEH1p/kr4AT4E=";
    };
    dependencies = with py; [
      anyio
      httpx2
      jsonschema
      mcpTypes
      opentelemetry-api
      pydantic
      pyjwt
      cryptography
      python-multipart
      sse-starlette
      starlette
      typing-extensions
      typing-inspection
      uvicorn
    ];
    pythonImportsCheck = [ "mcp.server.mcpserver" ];
    meta = {
      description = "Model Context Protocol SDK 2.x (required by comfy-mcp)";
      homepage = "https://github.com/modelcontextprotocol/python-sdk";
      license = lib.licenses.mit;
      sourceProvenance = with lib.sourceTypes; [ binaryWheel ];
    };
  };

  comfyCli = py.buildPythonPackage rec {
    pname = "comfy-cli";
    version = "1.20.0";
    format = "wheel";
    src = pkgs.fetchurl {
      url = "https://files.pythonhosted.org/packages/21/5c/38ce566cfec9fa596da3035cd7a472cdf0b35aecc84bfa6592786c86e8da/comfy_cli-1.20.0-py3-none-any.whl";
      hash = "sha256-xGkB/md++SR4tRGnU8oK5gO7aVnUpL5qI4O47JvfD/g=";
    };
    dependencies = with py; [
      certifi
      charset-normalizer
      cookiecutter
      gitpython
      httpx
      mixpanel
      packaging
      pathspec
      posthog
      psutil
      pyyaml
      questionary
      requests
      rich
      ruff
      semver
      tomlkit
      typer
      typing-extensions
      uv
      websocket-client
      imageio-ffmpeg
      blake3
    ];
    # nixpkgs ships mixpanel 5.0.0 (comfy-cli's <5 pin only dodges a pydantic
    # clash inside ComfyUI's env, not this one) and blake3 1.0.8 (floor 1.0.9);
    # relax those two metadata ranges so the runtime-deps check passes.
    pythonRelaxDeps = [
      "mixpanel"
      "blake3"
    ];
    pythonImportsCheck = [ "comfy_cli" ];
    meta = {
      description = "ComfyUI CLI (engine behind comfy-mcp's tools)";
      homepage = "https://github.com/Comfy-Org/comfy-cli";
      license = lib.licenses.gpl3Only;
      sourceProvenance = with lib.sourceTypes; [ binaryWheel ];
    };
  };

  comfyMcp = py.buildPythonPackage rec {
    pname = "comfy-mcp";
    version = "0.10.0";
    format = "wheel";
    src = pkgs.fetchurl {
      url = "https://files.pythonhosted.org/packages/b7/ba/b6adfb517983a5eed2d86b7b4e8199dc42aa2b028ef7d8b05f61f721195f/comfy_mcp-0.10.0-py3-none-any.whl";
      hash = "sha256-I/XgKphlpU2FgR6aQkK+ypEUAOCDo8je2+uwcwm67LA=";
    };
    dependencies = with py; [
      mcpSdk
      pydantic
      anyio
    ];
    pythonImportsCheck = [ "comfy_mcp" ];
    meta = {
      description = "Official ComfyUI MCP server (stdio, wraps comfy-cli)";
      homepage = "https://github.com/Comfy-Org/comfy-mcp";
      license = lib.licenses.agpl3Plus;
      sourceProvenance = with lib.sourceTypes; [ binaryWheel ];
    };
  };

  # One env exposes both console scripts (`comfy` and `comfy-mcp`).
  comfyMcpEnv = pkgs.python312.withPackages (_: [
    comfyCli
    comfyMcp
  ]);

  # Expose only the two binaries through the user profile, not the python env
  # itself: the per-user profile buildEnv installs extra outputs (man, info,
  # doc) of anything it can find one on, and the python env inherits
  # passthru.doc from the interpreter — whose docs are broken to build in the
  # locked nixpkgs and absent from the binary cache. The wrapper package has
  # no such attachment, and its symlinks keep the env in the user closure.
  comfyMcpTools = pkgs.runCommand "comfy-mcp-tools" { } ''
    mkdir -p $out/bin
    ln -s ${comfyMcpEnv}/bin/comfy $out/bin/comfy
    ln -s ${comfyMcpEnv}/bin/comfy-mcp $out/bin/comfy-mcp
  '';
in
{
  # comfy-mcp + comfy-cli on the configured users' PATH (cfg.comfyui.mcpUsers).
  # The per-user profile path is stable across rebuilds, so MCP clients can
  # reference it by absolute path:
  #   /etc/profiles/per-user/<user>/bin/comfy-mcp
  #   /etc/profiles/per-user/<user>/bin/comfy
  config = lib.mkIf (config.cfg.comfyui.mcpUsers != [ ]) {
    users.users = lib.genAttrs config.cfg.comfyui.mcpUsers (_: {
      packages = [ comfyMcpTools ];
    });
  };
}