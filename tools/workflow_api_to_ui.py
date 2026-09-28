#!/usr/bin/env python3
# Authoring-time helper: convert a ComfyUI API-format workflow JSON into
# UI-format (nodes/links). The frontend's workflow browser only renders
# UI-format graphs, but workflows submitted/generated via the HTTP API are
# API-format — this bridges that gap so runnable, browser-renderable
# workflows can be persisted into user/default/workflows/.
#
# Usage:  python3 tools/workflow_api_to_ui.py IN_API.json [OUT_UI.json]
#         (OUT defaults to IN with a .ui.json suffix)
# Server: COMFY_HOST env var, default http://127.0.0.1:8188
#
# The conversion is schema-driven from the running server's /object_info
# (widget ordering, control_after_generate states, converted-widget sockets
# like GetImageSize->Flux2Scheduler INT links, optional-socket elision), so it
# stays correct across node-pack updates. Validate the result with:
#   comfy workflow validate --workflow OUT_UI.json
import json
import os
import sys
import urllib.request

HOST = os.environ.get("COMFY_HOST", "http://127.0.0.1:8188")
_cache = {}

# Types that always render as sockets regardless of context (SaveText.text etc.)
_FORCE_SOCKET_TYPES = set()
# Widget-convertible types: they appear as node outputs yet their inputs are
# widgets that may carry converted links (GetImageSize INT -> scheduler width).
_WIDGET_TYPES = {"INT", "FLOAT", "STRING", "BOOLEAN", "COMBO"}


def schema(node_type):
    if node_type not in _cache:
        with urllib.request.urlopen(f"{HOST}/object_info/{node_type}", timeout=15) as r:
            _cache[node_type] = json.load(r)[node_type]
    return _cache[node_type]


def is_link(v):
    return isinstance(v, list) and len(v) == 2 and isinstance(v[0], str) and isinstance(v[1], int)


def convert_full(graph):
    # Socket-type universe: every type some used node outputs, minus widget-
    # convertible types. STRING is excluded — it is dual-natured (Florence2Run
    # outputs STRING but CLIPLoader-style text inputs are widgets); genuine
    # STRING sockets always declare forceInput.
    sock_types = set()
    for spec in graph.values():
        s = schema(spec["class_type"])
        sock_types.update(s.get("output", []))
    sock_types -= _WIDGET_TYPES

    # Layering for left-to-right layout.
    deps = {}
    for nid, spec in graph.items():
        deps[nid] = [v[0] for v in spec["inputs"].values() if is_link(v)]
    layer = {}

    def depth(nid, seen=()):
        if nid in layer:
            return layer[nid]
        layer[nid] = 0 if not deps[nid] else 1 + max(
            (depth(d, seen + (nid,)) for d in deps[nid] if d not in seen), default=0)
        return layer[nid]

    for nid in graph:
        depth(nid)

    nodes, links = [], []
    node_by_id = {}

    for nid in sorted(graph, key=lambda n: (layer[n], int(n))):
        spec = graph[nid]
        t = spec["class_type"]
        sch = schema(t)
        iorder = sch.get("input_order", {})
        req_names = iorder.get("required") or list(sch["input"].get("required", {}))
        opt_names = iorder.get("optional") or list(sch["input"].get("optional", {}))

        node_inputs, widgets = [], []
        for section, names in (("required", req_names), ("optional", opt_names)):
            for name in names:
                decl = sch["input"].get(section, {}).get(name)
                if decl is None:
                    continue
                typ = decl[0]
                if isinstance(typ, list):
                    typ = "COMBO"  # combo declarations carry the options list
                meta = decl[1] if len(decl) > 1 and isinstance(decl[1], dict) else {}
                aval = spec["inputs"].get(name, "__MISSING__")
                force_socket = typ in sock_types or bool(meta.get("forceInput"))

                if is_link(aval):
                    entry = {"name": name, "type": typ, "link": None}
                    if section == "optional":
                        entry["shape"] = 7
                    node_inputs.append(entry)
                    if not force_socket:
                        # converted widget: socket + retained widget value
                        widgets.append(meta.get("default"))
                elif force_socket:
                    if section == "required":
                        node_inputs.append({"name": name, "type": typ, "link": None})
                    # unconnected optional socket: omitted; frontend renders it
                elif aval == "__MISSING__":
                    continue  # optional input absent from the graph entirely
                else:
                    widgets.append(aval)
                    if meta.get("control_after_generate"):
                        widgets.append("fixed")

        outs = []
        out_types = sch.get("output", [])
        out_names = sch.get("output_name") or out_types
        for i, (ot, onm) in enumerate(zip(out_types, out_names)):
            outs.append({"name": onm if onm else ot, "type": ot, "links": None, "slot_index": i})

        h = max(58, 40 + 26 * max(len(widgets), len(node_inputs), 1))
        size = [315, 314] if t == "LoadImage" else [340 if widgets else 260, h]
        node = {"id": int(nid), "type": t, "pos": [0, 0], "size": size, "flags": {},
                "order": layer[nid], "mode": 0, "inputs": node_inputs, "outputs": outs,
                "properties": {"Node name for S&R": t}, "widgets_values": widgets}
        nodes.append(node)
        node_by_id[int(nid)] = node

    # Resolve links; widget-converted INT/FLOAT sockets keep their widget slot.
    for dst_id, iname, (src_id, sslot) in sorted(
            [(int(nid), name, tuple(v)) for nid, spec in graph.items()
             for name, v in spec["inputs"].items() if is_link(v)],
            key=lambda x: (x[0], x[1])):
        dst, src = node_by_id[dst_id], node_by_id[int(src_id)]
        entry = next(e for e in dst["inputs"] if e["name"] == iname)
        lk = len(links) + 1
        links.append([lk, int(src_id), int(sslot), dst_id,
                      [i for i, e in enumerate(dst["inputs"]) if e["name"] == iname][0],
                      entry["type"]])
        entry["link"] = lk
        out = src["outputs"][int(sslot)]
        out["links"] = (out.get("links") or []) + [lk]

    # Layout: columns by depth, stacked within each column.
    by_layer = {}
    for n in nodes:
        by_layer.setdefault(n["order"], []).append(n)
    for lay in sorted(by_layer):
        y = 60
        for n in by_layer[lay]:
            n["pos"] = [40 + lay * 420, y]
            y += n["size"][1] + 40

    return {"last_node_id": max(n["id"] for n in nodes), "last_link_id": len(links) + 1,
            "nodes": nodes, "links": links, "groups": [], "config": {},
            "extra": {"ds": {"scale": 1.0, "offset": [0, 0]}}, "version": 0.4}


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else None
    dst = sys.argv[2] if len(sys.argv) > 2 else None
    if not src:
        print(__doc__)
        raise SystemExit(1)
    with open(src) as f:
        graph = json.load(f)
    ui = convert_full(graph)
    out = dst or (os.path.splitext(src)[0] + ".ui.json")
    with open(out, "w") as f:
        json.dump(ui, f, indent=1)
    print(f"{src} -> {out} ({len(ui['nodes'])} nodes, {len(ui['links'])} links)")


if __name__ == "__main__":
    import sys
    main()