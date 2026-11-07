# ponytail: patch vanilla RSC_ComputationScience (ResearchTechnology) so it also unlocks BPO_BlueprintUnit_C.
# Usage: python -I patch_research.py <OUT_DIR>   (writes RSC_ComputationScience.uasset/.uexp into OUT_DIR)
# Adds: 3 names (package path, 'BlueprintGeneratedClass', class), 2 imports (Package, BlueprintGeneratedClass), 1 preload ref (end of the
# SerializationBefore deps), 1 new 8-byte array element `80 0d 1e 03 <NEWREF>` inserted at the end of the
# block array, array count N -> N+1. Layout values are parsed from the vanilla file, not hardcoded.
# Header values are patched at fixed positions, each asserted against the parsed layout. verify() re-parses the output.
import struct
import sys
import os
import hashlib

OUT = sys.argv[1]
MODS_ROOT = os.environ.get('MS_MODS_ROOT', 'F:/MSDemoMods')  # repo root, holds legacy/ (vanilla source)
S = MODS_ROOT + '/legacy/MainSequence/Content/Data/Research/RSC_ComputationScience'
PK = '/Game/Blueprints/BuildingBlocks/BPO_BlueprintUnit'
CL = 'BPO_BlueprintUnit_C'

u32 = lambda b, q: struct.unpack_from('<i', b, q)[0]
a = open(S + '.uasset', 'rb').read()
B = 60 + u32(a, 52)  # NameCount offset: 56 + FolderName len @52 (incl NUL) + 4 PackageFlags. ML 96, CS 103
e = open(S + '.uexp', 'rb').read()

# vanilla layout (parsed)
NN, NO, IC, IO, EO = u32(a, B), u32(a, B + 4), u32(a, B + 32), u32(a, B + 36), u32(a, B + 28)
PLO, PLC = u32(a, B + 160), u32(a, B + 156)
assert u32(a, B + 24) == 1
SB = u32(a, EO + 84)                               # SerializationBefore count
VAN_HDR = len(a)
assert u32(a, 44) == VAN_HDR
VAN_SER = struct.unpack_from('<q', a, EO + 28)[0]  # export SerialSize
VAN_UEXP = len(e)
TAIL = len(a) - (PLO + 4 * PLC)
VAN_PL = [u32(a, PLO + 4 * i) for i in range(PLC)]  # vanilla preload list
NEWREF = -(IC + 2)                                 # class import index IC+1 (after package import IC)


def read_names(buf, n, p):
    out = []
    for _ in range(n):
        l = u32(buf, p)
        out.append(buf[p + 4:p + 3 + l].decode())
        p += 8 + l
    return out, p


def fs(s):
    b = s.encode() + b'\0'
    return struct.pack('<i', len(b)) + b + b'\0\0\0\0'


names, p = read_names(a, NN, NO)
assert p == IO and IO + 32 * IC == EO and EO + 104 == PLO
assert a[PLO + 4 * PLC:] == b'\0' * TAIL
ix = names.index

newnames = fs(PK) + fs('BlueprintGeneratedClass') + fs(CL)
A = len(newnames)
imp = struct.pack('<8i', ix('/Script/CoreUObject'), 0, ix('Package'), 0, 0, NN, 0, 0)
imp += struct.pack('<8i', ix('/Script/Engine'), 0, NN + 1, 0, -(IC + 1), NN + 2, 0, 0)
P3 = PLO + 4 * SB                                  # end of SerializationBefore deps
ins = [(IO, A), (EO, len(imp)), (P3, 4)]


def sh(v):
    return v + sum(l for pos, l in ins if v >= pos)


# ---- uexp: block array = [count][ [80 0d][mask][1-2 small values][i32 ref] per element ] ----
def parse_arr(buf):
    c = buf.index(b'\x80\x0d') - 4                 # array count sits right before the first element
    n, p = u32(buf, c), c + 4
    refs = []
    last = p
    for _ in range(n):
        assert buf[p:p + 2] == b'\x80\x0d'
        m = buf[p + 2]
        assert m in (0x1e, 0x1c, 0x3b), m
        L = {0x1e: 8, 0x1c: 9, 0x3b: 7}[m]
        refs.append(u32(buf, p + L - 4))
        last = p
        p += L
    return c, refs, p, last


c0, refs0, p0, pl = parse_arr(e)
VAN_REFS = refs0
ELEM = 8                                           # new element size: 80 0d 1e 03 + i32 ref
assert len(e) == VAN_SER + 4
assert e[p0:p0 + 4] == b'\0\0\0\0'

# header: fixed positions, asserted against the parsed layout
OFFS = {44: VAN_HDR, B + 12: IO, B + 28: EO, B + 36: IO, B + 44: PLO - 8, B + 52: PLO - 8, B + 60: PLO - 8,
        B + 136: PLO - 4, B + 140: VAN_HDR + VAN_SER, B + 160: PLO}
CNT = {B: (NN, NN + 3), B + 32: (IC, IC + 2), B + 156: (PLC, PLC + 1)}
h = bytearray(a[:NO])
for q, v in OFFS.items():
    assert u32(h, q) == v, (q, u32(h, q), v)
    struct.pack_into('<i', h, q, sh(v) + (ELEM if q == B + 140 else 0))   # BulkDataStart = header + export size
for q, (v, nv) in CNT.items():
    assert u32(h, q) == v, (q, u32(h, q), v)
    struct.pack_into('<i', h, q, nv)
h = bytes(h)

ex = bytearray(a[EO:PLO])                          # the one export entry (104 bytes)
assert struct.unpack_from('<q', ex, 28)[0] == VAN_SER and struct.unpack_from('<q', ex, 36)[0] == VAN_HDR
struct.pack_into('<q', ex, 28, VAN_SER + ELEM)     # SerialSize
struct.pack_into('<q', ex, 36, sh(VAN_HDR))        # SerialOffset = new header size
assert u32(ex, 84) == SB and u32(ex, 88) == 2
struct.pack_into('<i', ex, 84, SB + 1)
out = (h + a[NO:IO] + newnames + a[IO:EO] + imp + bytes(ex)
       + a[PLO:P3] + struct.pack('<i', NEWREF) + a[P3:])

new_elem = b'\x80\x0d\x1e\x03' + struct.pack('<i', NEWREF)
u = bytearray(e[:p0] + new_elem + e[p0:])
struct.pack_into('<i', u, c0, len(VAN_REFS) + 1)
u = bytes(u)


# ---- verify: parse the OUTPUT bytes and assert the layout ----
def verify(oa, oe):
    fail = []

    def chk(label, cond):
        print(('ok   ' if cond else 'FAIL ') + label)
        if not cond:
            fail.append(label)

    total = u32(oa, 44)
    chk('uasset length %d == TotalHeaderSize %d' % (len(oa), total), len(oa) == total)
    Bo = 60 + u32(oa, 52)
    nn, no, ic, io_ = u32(oa, Bo), u32(oa, Bo + 4), u32(oa, Bo + 32), u32(oa, Bo + 36)
    ec, eo, plc, plo = u32(oa, Bo + 24), u32(oa, Bo + 28), u32(oa, Bo + 156), u32(oa, Bo + 160)
    chk('NameCount %d == %d' % (nn, NN + 3), nn == NN + 3)
    chk('NameOffset == %d' % NO, no == NO)
    chk('ExportCount 1', ec == 1)
    chk('ImportCount %d == %d' % (ic, IC + 2), ic == IC + 2)
    chk('PreloadCount %d == %d' % (plc, PLC + 1), plc == PLC + 1)
    onames, p = read_names(oa, nn, no)
    chk('name table ends at ImportOffset (%d)' % io_, p == io_)
    chk('SoftObjectPathsOffset == ImportOffset', u32(oa, Bo + 12) == io_)
    chk('vanilla names kept', onames[:NN] == names and oa[NO:IO] == a[NO:IO])
    chk('name[%d] == %s' % (NN, PK), onames[NN] == PK)
    chk('name[%d] == BlueprintGeneratedClass' % (NN + 1), onames[NN + 1] == 'BlueprintGeneratedClass')
    chk('name[%d] == %s' % (NN + 2, CL), onames[NN + 2] == CL)
    chk('ExportOffset == ImportOffset + 32*ImportCount', eo == io_ + 32 * ic)
    chk('PreloadOffset == ExportOffset + 104', plo == eo + 104)
    chk('TotalHeaderSize == PreloadOffset + 4*PreloadCount + tail', total == plo + 4 * plc + TAIL)
    chk('tail zero bytes kept', oa[plo + 4 * plc:] == b'\0' * TAIL)
    chk('Depends/SoftPkg/Searchable offsets == PreloadOffset-8', u32(oa, Bo + 44) == u32(oa, Bo + 52) == u32(oa, Bo + 60) == plo - 8)
    chk('AssetRegistry offset == PreloadOffset-4', u32(oa, Bo + 136) == plo - 4)
    chk('vanilla import bytes unchanged', oa[io_:io_ + 32 * IC] == a[IO:IO + 32 * IC])
    pkg = struct.unpack_from('<8i', oa, io_ + 32 * IC)
    cls = struct.unpack_from('<8i', oa, io_ + 32 * (IC + 1))
    chk('import[%d] Package, outer 0, name %d' % (IC, NN),
        onames[pkg[0]] == '/Script/CoreUObject' and onames[pkg[2]] == 'Package' and pkg[4] == 0 and pkg[5] == NN)
    chk('import[%d] BlueprintGeneratedClass, outer -(%d), name %d' % (IC + 1, IC + 1, NN + 2),
        onames[cls[0]] == '/Script/Engine' and onames[cls[2]] == 'BlueprintGeneratedClass' and cls[4] == -(IC + 1) and cls[5] == NN + 2)
    ser = struct.unpack_from('<q', oa, eo + 28)[0]
    off = struct.unpack_from('<q', oa, eo + 36)[0]
    chk('export SerialSize %d == %d' % (ser, VAN_SER + ELEM), ser == VAN_SER + ELEM)
    chk('export SerialOffset %d == TotalHeaderSize' % off, off == total)
    chk('export SerializationBefore count == %d, CreateBefore 2' % (SB + 1), u32(oa, eo + 84) == SB + 1 and u32(oa, eo + 88) == 2)
    ex2, exv = bytearray(oa[eo:eo + 104]), bytearray(a[EO:PLO])
    for q in (28, 36):
        ex2[q:q + 8] = exv[q:q + 8]
    ex2[84:88] = exv[84:88]
    chk('rest of export entry unchanged', bytes(ex2) == bytes(exv))
    pref = [u32(oa, plo + 4 * i) for i in range(plc)]
    want = VAN_PL[:SB] + [NEWREF] + VAN_PL[SB:]
    chk('preload == %s' % want, pref == want)
    bulk = u32(oa, Bo + 140)
    chk('BulkDataStart %d == TotalHeaderSize + SerialSize %d' % (bulk, total + ser), bulk == total + ser)
    chk('uexp length %d == SerialSize + 4 footer' % len(oe), len(oe) == ser + 4)
    c, refs, pe, _ = parse_arr(oe)
    chk('array count %d == %d' % (u32(oe, c), len(VAN_REFS) + 1), u32(oe, c) == len(VAN_REFS) + 1)
    chk('array vanilla refs intact in order', refs[:len(VAN_REFS)] == VAN_REFS)
    chk('array last ref == %d (BlueprintUnit class import)' % NEWREF, refs[len(VAN_REFS):] == [NEWREF])
    chk('uexp prefix before count unchanged', oe[:c] == e[:c])
    chk('uexp vanilla elements unchanged', oe[c + 4:p0] == e[c0 + 4:p0])
    chk('uexp tail (after array) unchanged', oe[pe:] == e[p0:])
    diff = {q for q in range(NO) if oa[q] != a[q]}
    allowed = {q + i for q in list(OFFS) + list(CNT) for i in range(4)}
    chk('header bytes changed only at patched positions', diff <= allowed)
    print('RESULT ' + ('PASS' if not fail else 'FAIL %d' % len(fail)))
    return not fail


os.makedirs(OUT, exist_ok=True)
open(os.path.join(OUT, 'RSC_ComputationScience.uasset'), 'wb').write(out)
open(os.path.join(OUT, 'RSC_ComputationScience.uexp'), 'wb').write(u)
print('names+3 imports+2 preload+1 array %d->%d (new element %d bytes)' % (len(VAN_REFS), len(VAN_REFS) + 1, ELEM))
print('uasset %d -> %d   uexp %d -> %d' % (len(a), len(out), len(e), len(u)))
for fn in ['RSC_ComputationScience.uasset', 'RSC_ComputationScience.uexp']:
    print(hashlib.sha256(open(os.path.join(OUT, fn), 'rb').read()).hexdigest(), fn)
sys.exit(0 if verify(out, u) else 1)
