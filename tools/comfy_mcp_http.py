"""Serve comfy-mcp over streamable HTTP for local clients.

comfy-mcp's own entry point only speaks stdio, so every client spawns a
private copy. This launcher imports the same server object and runs it with
the MCP SDK's streamable-http transport instead, so one systemd unit
(modules/mcp.nix) can serve every local client on 127.0.0.1.

Changes against the stdio server:

- Removed tools: the comfy-cli lifecycle verbs (systemd owns the service),
  install_node and download_model (node packs and models are declared in
  nix), and the partner-API login (one stored login would serve every
  client).
- Added tool: stage_workflow, which stores workflow JSON in the service's
  own workspace and returns its path. Every path-taking tool reads paths on
  this machine, so a client without access to this filesystem stages the
  workflow first and passes the returned path on.
- The handshake instructions gain a short note on both.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import tempfile
from pathlib import Path
from typing import Any

from mcp.server.mcpserver.exceptions import ToolError

from comfy_mcp import instructions, server

REMOVED_TOOLS = (
    "launch_comfyui",
    "stop_comfyui",
    "restart_comfyui",
    "update_comfyui",
    "switch_comfyui_version",
    "install_node",
    "download_model",
    "auth_login",
)

SHARED_NOTE = """
## This deployment

This server is a shared HTTP service, not a per-client subprocess:

- Every path argument is a path on the server's machine, not the
  client's. Relative paths resolve against the server's workspace.
- To run, validate or vary a workflow you hold as JSON, call
  `stage_workflow` with it and pass the returned `workflow_path` to
  `run_workflow`, `validate_workflow`, `set_workflow_slot` or
  `vary_workflow`.
- To get outputs back, call `fetch_outputs` with a relative `out_dir`
  (e.g. "outputs") and `inline_images=True`, or with `url_only=True`.
- ComfyUI runs under systemd; the lifecycle, node-install, model-download
  and login tools are not available here.
"""


def _remove_tools() -> None:
    for name in REMOVED_TOOLS:
        try:
            server.mcp.remove_tool(name)
        except ToolError:
            # Not in this comfy-mcp version; nothing to remove.
            pass


def _register_stage_workflow(stage_dir: Path) -> None:
    @server.mcp.tool()
    def stage_workflow(workflow: dict[str, Any]) -> dict[str, str]:
        """Store a workflow (API or UI format JSON object) on the server.

        Returns ``workflow_path``, a server-side path for the path-taking
        tools (``run_workflow``, ``validate_workflow``, ``set_workflow_slot``,
        ``vary_workflow``). Files are named by content hash, so staging the
        same workflow twice returns the same path.
        """
        data = json.dumps(workflow, sort_keys=True, separators=(",", ":")).encode()
        path = stage_dir / f"{hashlib.sha256(data).hexdigest()}.json"
        if not path.exists():
            fd, tmp = tempfile.mkstemp(dir=stage_dir, suffix=".tmp")
            with os.fdopen(fd, "wb") as fh:
                fh.write(data)
            os.replace(tmp, path)
        return {"workflow_path": str(path)}


def _apply_instructions() -> None:
    # comfy-mcp's startup hook adds a machine snapshot to the handshake
    # instructions; it is private, so a release without it just skips it.
    startup = getattr(server, "_apply_startup_instructions", None)
    if startup is not None:
        startup()
    current = server.mcp.instructions or instructions.INSTRUCTIONS
    # Same low-level attribute comfy-mcp writes: the public property is
    # read-only.
    server.mcp._lowlevel_server.instructions = f"{current}\n{SHARED_NOTE}"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--stage-dir", type=Path, required=True)
    args = parser.parse_args()

    args.stage_dir.mkdir(parents=True, exist_ok=True)
    _remove_tools()
    _register_stage_workflow(args.stage_dir)
    _apply_instructions()
    server.mcp.run(transport="streamable-http", host=args.host, port=args.port)


if __name__ == "__main__":
    main()
