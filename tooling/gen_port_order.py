#!/usr/bin/env python3
"""gen_port_order.py: writes mods/BlueprintUnit/Scripts/bpu_port_data.lua.

Inputs (website + REA data, read only):
  REA machines.json  inputs_by_side / outputs_by_side (1-based position along side), size_cells [W,H]
  site catalog.js    buildables[].portsLayout.ports ({face, pos}) in site Index order (0-based index)

Coordinates: half cells, origin = machine centre, y down (website view). A side position p (1-based)
of a W x H machine gives: E (W, 2(p-1)-(H-1)), W (-W, same), S (2(p-1)-(W-1), H), N (same, -H).
Rotation step (clockwise in y-down view): (x, y) -> (-y, x).

Game order (rot 0), RULE: clockwise from East, top-most first:
  E by y asc, S by x desc, W by y desc, N by x asc.
Verified by probe (in game): Refinery and Assembler only. Everything else is rule-derived.

Run: python tooling/gen_port_order.py [--rea path] [--catalog path]
"""
import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.normpath(os.path.join(HERE, "..", "mods", "BlueprintUnit", "Scripts", "bpu_port_data.lua"))
DEF_REA = r"F:\MSDemoMods-public\tools\factory-blueprint\extract\rea\machines.json"
DEF_CAT = r"F:\ms-factory-bp-site\js\catalog.js"
VERIFIED = {
    "DAT_Refinery": [(3, 0), (0, 3), (-3, 0), (0, -3)],
    "DAT_Assembler": [(5, -2), (5, 2), (2, 5), (-2, 5), (-5, 2), (-5, -2), (-2, -5), (2, -5)],
}
FACE_GROUP = {"E": 0, "S": 1, "W": 2, "N": 3}


def cell(face, pos, w, h):
    """side position (1-based) -> (x, y) in half-cell units, rot 0."""
    c = pos - 1
    if face == "E":
        return (w, 2 * c - (h - 1))
    if face == "W":
        return (-w, 2 * c - (h - 1))
    if face == "S":
        return (2 * c - (w - 1), h)
    if face == "N":
        return (2 * c - (w - 1), -h)
    raise ValueError("bad face " + str(face))


def rule_key(xy, face):
    x, y = xy
    within = {"E": y, "S": -x, "W": -y, "N": x}[face]
    return (FACE_GROUP[face], within)


def side_ports(by_side):
    """{face: [pos,...]} -> [(face, pos), ...]"""
    out = []
    for face in ("E", "S", "W", "N"):
        for pos in (by_side or {}).get(face) or []:
            out.append((face, int(pos)))
    return out


def lua_cells(cells):
    return "{" + ",".join("{%d,%d}" % (x, y) for x, y in cells) + "}"


def load_catalog(path):
    text = open(path, encoding="utf-8").read()
    data = json.loads(text[text.index("{"): text.rindex("}") + 1])
    return {"DAT_" + b["name"]: b for b in data.get("buildables", []) if b.get("portsLayout")}


def build(rea_path, cat_path):
    rea = json.load(open(rea_path, encoding="utf-8"))
    site = load_catalog(cat_path)
    classes = {}
    problems = []
    for dat in sorted(rea):
        e = rea[dat]
        ins = side_ports(e.get("inputs_by_side"))
        outs = side_ports(e.get("outputs_by_side"))
        if not ins and not outs:
            continue
        w, h = e["size_cells"]
        same = bool(e.get("outputs_same_as_inputs")) or not outs
        ports = ins if same else ins + outs
        cells = [cell(f, p, w, h) for f, p in ports]
        pairs = list(zip(cells, [f for f, _ in ports]))
        pairs.sort(key=lambda t: rule_key(t[0], t[1]))
        ordered = [c for c, _ in pairs]
        note = None
        if len(set(ordered)) != len(ordered):
            note = "duplicate cells in data"
        if e.get("port_boundary_cells") and list(e["port_boundary_cells"]) != [w, h]:
            note = (note + "; " if note else "") + "port_boundary_cells %s != size %s" % (e["port_boundary_cells"], [w, h])
        rec = {"cells": ordered, "verified": False, "note": None, "site": None}
        if not same:
            note = (note + "; " if note else "") + "inputs and outputs listed separately, order unknown"
        rec["note"] = note

        sd = site.get(dat)
        if sd:
            sp = sd["portsLayout"]["ports"]
            site_list = []
            for i, q in enumerate(sp):
                if not isinstance(q["pos"], int):
                    raise SystemExit("non-numeric pos in site layout " + dat)
                x, y = cell(q["face"], q["pos"], w, h)
                site_list.append({"face": q["face"], "index": i, "x": x, "y": y})
            site_set = sorted(((s["x"], s["y"]) for s in site_list))
            data_set = sorted(ordered)
            if site_set != data_set:
                rec["note"] = (rec["note"] + "; " if rec["note"] else "") + "site layout cells differ from REA data"
            rec["site"] = site_list
        if dat in VERIFIED:
            if ordered != VERIFIED[dat]:
                problems.append("%s: generated %s != verified %s" % (dat, ordered, VERIFIED[dat]))
            if rec["site"] is None:
                problems.append("%s: no site layout" % dat)
            rec["verified"] = True
            rec["note"] = None
        else:
            rec["note"] = "rule-derived, needs probe" + ("; " + rec["note"] if rec["note"] else "")
        classes[dat] = rec
    for dat in VERIFIED:
        if dat not in classes:
            problems.append("%s: missing from REA data" % dat)
    return classes, problems


def emit(classes):
    lines = [
        "-- GENERATED by tooling/gen_port_order.py: do not edit",
        "-- Port order per machine class (DAT name) at rot 0. Units: half cells, origin = machine centre, y down.",
        "-- cells: game byte order (index 1 = first). verified=true only where the probe confirmed the order.",
        "-- site: website portsLayout order, index = export Index (0-based), x/y = cell at rot 0.",
        "return {",
    ]
    for dat, r in classes.items():
        parts = ["verified = %s" % ("true" if r["verified"] else "false"), "cells = %s" % lua_cells(r["cells"])]
        if r["site"] is not None:
            parts.append("site = {" + ",".join('{face="%s",index=%d,x=%d,y=%d}' % (s["face"], s["index"], s["x"], s["y"]) for s in r["site"]) + "}")
        if r["note"]:
            parts.append("note = %s" % json.dumps(r["note"]))
        lines.append("    %s = { %s }," % (dat, ", ".join(parts)))
    lines.append("}")
    return "\n".join(lines) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rea", default=DEF_REA)
    ap.add_argument("--catalog", default=DEF_CAT)
    ap.add_argument("--out", default=OUT)
    a = ap.parse_args()
    classes, problems = build(a.rea, a.catalog)
    if problems:
        for p in problems:
            print("ERROR " + p, file=sys.stderr)
        return 1
    with open(a.out, "w", encoding="utf-8", newline="\n") as f:
        f.write(emit(classes))
    n_ver = sum(1 for r in classes.values() if r["verified"])
    print("wrote %s: %d classes with ports, %d verified" % (a.out, len(classes), n_ver))
    for dat, r in classes.items():
        if not r["verified"]:
            print("  unverified %s (%d ports)" % (dat, len(r["cells"])))
    return 0


if __name__ == "__main__":
    sys.exit(main())
