"""Scan cooked .uasset/.uexp under DIR for /Game/ refs outside /Game/BlueprintUnitUI/ (used by bpunit_pack.ps1).
Usage: python -I bpunit_refscan.py DIR. Exit 1 on any hit. Same rule as tests\test_asset_refs.py --cooked, own prefix."""
import os
import re
import sys

OWN = "/Game/BlueprintUnitUI/"
RE = re.compile(rb"/Game/[A-Za-z0-9_./-]+")

hits = []
for dp, _, fs in os.walk(sys.argv[1]):
    for f in fs:
        if f.lower().endswith((".uasset", ".uexp")):
            data = open(os.path.join(dp, f), "rb").read().replace(b"\x00", b"")
            for m in sorted({m.decode("ascii") for m in RE.findall(data)}):
                if not (m == OWN[:-1] or m.startswith(OWN)):
                    hits.append("%s: %s" % (f, m))
for h in hits:
    print(h)
print("bpunit refscan: %d hit(s)" % len(hits))
sys.exit(1 if hits else 0)
