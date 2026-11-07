# S1 step 5: add the hidden container machine to DefaultMachines of stage BPO_BlueprintUnit (clone of vanilla BPO_CommandModule).
# The vanilla CONNECTOR array (uexp 374, BPO_LargeConnector_C) is NOT touched.
# DefaultMachines is a separate property = unversioned-header index 24, absent in BPO_CommandModule. So the export 1 header
# gains idx 24 (uexp 116-117 `07 02` -> `02 02 04 02`) and its 22-byte value goes right before idx 29's value.
# Element now = count | 80 09 0c | class | 80 07 06 (Transform, mask 06 = Height+Rotation omitted) | X i32 | Y i32 (22 bytes).
# X, Y = machine units relative to block origin (env BPU_MX / BPU_MY, default 8, 8).
# Patches the .uasset/.uexp in place.
# Usage: python -I patch_bpo_machine.py <DIR with BPO_BlueprintUnit.uasset/.uexp> <CLASS PACKAGE> <CLASS NAME>
#        python -I patch_bpo_machine.py --walk <base path without ext>   (print CONNECTOR array walk only)
#   vanilla container: <CLASS PACKAGE>=/Game/Blueprints/Machines/BP_ContainerObject_2  <CLASS NAME>=BP_ContainerObject_2_C
#   clone container:   <CLASS PACKAGE>=/Game/Blueprints/Machines/BP_BPUnitStoreObj_01  <CLASS NAME>=BP_BPUnitStoreObj_01_C
# Layout is parsed and asserted, not hardcoded. verify() re-parses the output bytes before anything is written.
# ponytail: X,Y tuned by live test only (8,8 primary; fallbacks 8,10 / 10,10 / 16,16). Scale assumed, not verified.
import struct
import sys
import os
import hashlib

CONNECTOR = 'BPO_LargeConnector_C'
DM = 374             # uexp offset of the CONNECTOR array count (vanilla: 1). Not changed by this script.
EXP_STRIDE = 96      # export table entry size in this file (chain-checked below)
HDR = 104            # uexp offset of export 1 unversioned property header
HDR_VANILLA = bytes.fromhex('00 0c 01 02 02 04 02 04 01 02 02 04 07 02 07 03')
HDR_IDX = [0, 1, 2, 3, 4, 5, 7, 10, 11, 14, 15, 17, 20, 21, 29, 37]
IDX_DM = 24          # unversioned property index of DefaultMachines
MX, MY = int(os.environ.get('BPU_MX', 8)), int(os.environ.get('BPU_MY', 8))   # machine position (int32 each)
HDR_NEW = bytes.fromhex('02 02 04 02')   # replaces vanilla '07 02' at HDR+12: skip 2 -> idx 24, skip 4 -> idx 29
GROW = 24            # export 1 SerialSize growth: 2 header bytes + 22 value bytes
GROW_HDR = 2         # the header bytes shift everything after uexp 118 (connector array 374 -> 376, its end 404 -> 406)
TAIL = 18            # from idx 29 value to uexp end: ff*4, idx 37 (6 bytes), trailer (4), footer (4)

i32 = lambda b, q: struct.unpack_from('<i', b, q)[0]
i64 = lambda b, q: struct.unpack_from('<q', b, q)[0]


def fs(s):  # FString name entry + 4 zero bytes hash (same as patch_research.py)
    b = s.encode() + b'\0'
    return struct.pack('<i', len(b)) + b + b'\0\0\0\0'


def read_names(buf, n, p):
    out = []
    for _ in range(n):
        l = i32(buf, p)
        out.append(buf[p + 4:p + 3 + l].decode('latin1'))
        p += 8 + l
    return out, p


def walk(e, dm=DM):
    # CONNECTOR array at dm: count, then per element: 80 0b 0c | class ref i32 | 80 07 tmask | X i32 | Y i32 | [Rot i32 if !(tmask&4)] | cfg count i32 (0)
    n = i32(e, dm)
    p = dm + 4
    out = []
    for _ in range(n):
        assert e[p:p + 2] == b'\x80\x0b' and e[p + 2] == 0x0c, ('struct header', p)
        ref = i32(e, p + 3)
        p += 7
        assert e[p:p + 2] == b'\x80\x07' and e[p + 2] in (0x02, 0x06), ('transform header', p)
        tm = e[p + 2]
        p += 3
        x, y = i32(e, p), i32(e, p + 4)
        p += 8
        rot = None
        if not tm & 0x04:
            rot = i32(e, p)
            p += 4
        cfg = i32(e, p)
        assert cfg == 0, ('config bytes not handled', p)
        p += 4
        out.append(dict(ref=ref, x=x, y=y, rot=rot, tmask=tm))
    return out, p, i32(e, p)


def hdr_idx(e):
    # unversioned header from HDR: uint16 fragments (skip = v&0x7f, zero-mask = v&0x80, last = v&0x100, values = v>>9)
    p, cur, out = HDR, 0, []
    while True:
        v = struct.unpack_from('<H', e, p)[0]
        p += 2
        assert not v & 0x80, 'zero mask in header not handled'
        cur += v & 0x7f
        for _ in range(v >> 9):
            out.append(cur)
            cur += 1
        if v & 0x100:
            return out, p


def value(ref):
    # DefaultMachines value (22 bytes): count 1 | 80 09 0c | class ref | 80 07 06 | X i32 | Y i32
    return (struct.pack('<i', 1) + b'\x80\x09\x0c' + struct.pack('<i', ref)
            + b'\x80\x07\x06' + struct.pack('<ii', MX, MY))


if sys.argv[1] == '--walk':
    base = sys.argv[2]
    els, end, nxt = walk(open(base + '.uexp', 'rb').read())
    print('elements', len(els), 'end', end, 'next int32', nxt)
    for el in els:
        print('  ', el)
    sys.exit(0)

if len(sys.argv) != 4:
    sys.exit('usage: patch_bpo_machine.py <DIR> <CLASS PACKAGE> <CLASS NAME>  |  --walk <base>')
NEW_PKG, NEW_CLS = sys.argv[2], sys.argv[3]
BASE = os.path.join(sys.argv[1], 'BPO_BlueprintUnit')
a = open(BASE + '.uasset', 'rb').read()
e = open(BASE + '.uexp', 'rb').read()
L = len(e)

# ---- vanilla layout (parsed + asserted) ----
B = 60 + i32(a, 52)
NN, NO, IC, IO = i32(a, B), i32(a, B + 4), i32(a, B + 32), i32(a, B + 36)
EC, EO = i32(a, B + 24), i32(a, B + 28)
PLC, PLO = i32(a, B + 156), i32(a, B + 160)
TOT = i32(a, 44)
assert TOT == len(a) and EC == 2 and IO + 32 * IC == EO and i32(a, B + 12) == IO
assert i32(a, B + 44) == i32(a, B + 52) == i32(a, B + 60) == EO + EXP_STRIDE * EC
assert i32(a, B + 136) == PLO - 4
names, p = read_names(a, NN, NO)
assert p == IO, 'name table does not end at ImportOffset'
ix = names.index
for s in ('/Script/CoreUObject', 'Package', '/Script/Engine', 'BlueprintGeneratedClass', CONNECTOR):
    assert s in names, s
assert NEW_PKG not in names and NEW_CLS not in names


def export(k):
    b = EO + EXP_STRIDE * k
    return dict(at=b, ser=i64(a, b + 28), off=i64(a, b + 36), fed=i32(a, b + 76),
                sb=i32(a, b + 80), cb=i32(a, b + 84), sbc=i32(a, b + 88), cbc=i32(a, b + 92))


X0, X1 = export(0), export(1)
assert X0['off'] == TOT and X1['off'] == TOT + X0['ser'] and TOT + X0['ser'] + X1['ser'] == TOT + L - 4
assert i32(a, B + 140) == TOT + X0['ser'] + X1['ser'], 'BulkDataStart layout'
assert X0['fed'] == 0 and X1['fed'] == X0['sb'] + X0['cb'] + X0['sbc'] + X0['cbc']
assert X1['fed'] + X1['sb'] + X1['cb'] + X1['sbc'] + X1['cbc'] == PLC
PL = [i32(a, PLO + 4 * i) for i in range(PLC)]

conn_idx = [i for i in range(IC) if names[struct.unpack_from('<8i', a, IO + 32 * i)[5]] == CONNECTOR]
assert len(conn_idx) == 1
CONN_REF = -(conn_idx[0] + 1)
cb0 = X1['fed'] + X1['sb']
assert CONN_REF in PL[cb0:cb0 + X1['cb']], 'connector not in export 1 CreateBefore block'

# CONNECTOR array (uexp 374) is not touched: count 1, BPO_LargeConnector_C, end 404, next int 20
els0, end0, nxt0 = walk(e)  # uexp 374 -> connector end 404 in vanilla
assert len(els0) == 1 and els0[0]['ref'] == CONN_REF and end0 == 404 and nxt0 == 20
assert X1['off'] - TOT <= DM < X1['off'] - TOT + X1['ser']

# export 1 unversioned header: vanilla idx set, no idx 24 yet
assert e[HDR:HDR + 16] == HDR_VANILLA, 'header bytes at uexp 104 differ from vanilla'
assert e[HDR + 12:HDR + 14] == b'\x07\x02'
idx0, hend0 = hdr_idx(e)
assert idx0 == HDR_IDX and hend0 == HDR + 16 and IDX_DM not in idx0, idx0

# tail: idx 29 value (ff ff ff ff), idx 37 (01 03 ..), trailer, footer
INS = L - TAIL
assert e[INS:INS + 4] == b'\xff' * 4 and e[INS + 4:INS + 6] == b'\x01\x03', 'idx 29/37 tail layout'
assert e[-4:] == b'\xc1\x83\x2a\x9e' and e[-8:-4] == b'\0\0\0\0'

# ---- new names / imports / preload ----
NEWREF = -(IC + 2)                    # new class import index IC+1 -> ref -(IC+2)
newnames = fs(NEW_PKG) + fs(NEW_CLS)
A = len(newnames)
imp = struct.pack('<8i', ix('/Script/CoreUObject'), 0, ix('Package'), 0, 0, NN, 0, 0)
imp += struct.pack('<8i', ix('/Script/Engine'), 0, ix('BlueprintGeneratedClass'), 0, -(IC + 1), NN + 1, 0, 0)
PIDX = cb0 + X1['cb']                 # preload index = end of export 1 CreateBefore block (where the connector sits)
P3 = PLO + 4 * PIDX
ins = [(IO, A), (EO, len(imp)), (P3, 4)]


def sh(v):
    return v + sum(l for pos, l in ins if v >= pos)


TOTN = sh(TOT)
VAL = value(NEWREF)
assert len(VAL) == 22

# ---- uasset header ----
h = bytearray(a[:NO])
OFF_FIELDS = [44, B + 12, B + 28, B + 36, B + 44, B + 52, B + 60, B + 136, B + 160]
for q in OFF_FIELDS:
    struct.pack_into('<i', h, q, sh(i32(a, q)))
struct.pack_into('<i', h, B, NN + 2)
struct.pack_into('<i', h, B + 32, IC + 2)
struct.pack_into('<i', h, B + 156, PLC + 1)
struct.pack_into('<i', h, B + 140, TOTN + X0['ser'] + X1['ser'] + GROW)   # BulkDataStart
h = bytes(h)

ex = bytearray(a[EO:EO + EXP_STRIDE * EC])
for k, x in enumerate((X0, X1)):
    struct.pack_into('<q', ex, EXP_STRIDE * k + 36, sh(x['off']))      # both exports start before the change: offset only moves with header
struct.pack_into('<q', ex, EXP_STRIDE + 28, X1['ser'] + GROW)
struct.pack_into('<i', ex, EXP_STRIDE + 84, X1['cb'] + 1)
ex = bytes(ex)

out_a = (h + a[NO:IO] + newnames + a[IO:EO] + imp + ex + a[EO + EXP_STRIDE * EC:P3]
         + struct.pack('<i', NEWREF) + a[P3:])

# ---- uexp: header gets idx 24 (+2 bytes), value (14 bytes) inserted before idx 29 value ----
out_e = e[:HDR + 12] + HDR_NEW + e[HDR + 14:INS] + VAL + e[INS:]
NI = INS + GROW_HDR                   # inserted value start in out_e (header grew by 2)
assert len(out_e) == L + GROW and out_e[NI:NI + 22] == VAL


def verify(oa, oe):
    fail = []

    def chk(label, cond):
        print(('ok   ' if cond else 'FAIL ') + label)
        if not cond:
            fail.append(label)

    tot = i32(oa, 44)
    chk('uasset length %d == TotalHeaderSize %d' % (len(oa), tot), len(oa) == tot == TOTN)
    Bo = 60 + i32(oa, 52)
    nn, no, ic, io_ = i32(oa, Bo), i32(oa, Bo + 4), i32(oa, Bo + 32), i32(oa, Bo + 36)
    ec, eo, plc, plo = i32(oa, Bo + 24), i32(oa, Bo + 28), i32(oa, Bo + 156), i32(oa, Bo + 160)
    chk('NameCount %d == %d' % (nn, NN + 2), nn == NN + 2)
    chk('NameOffset == %d' % NO, no == NO)
    chk('ExportCount 2', ec == 2)
    chk('ImportCount %d == %d' % (ic, IC + 2), ic == IC + 2)
    chk('PreloadCount %d == %d' % (plc, PLC + 1), plc == PLC + 1)
    onames, p2 = read_names(oa, nn, no)
    chk('name table ends at ImportOffset (%d)' % io_, p2 == io_)
    chk('SoftObjectPathsOffset == ImportOffset', i32(oa, Bo + 12) == io_)
    chk('vanilla names kept', onames[:NN] == names and oa[NO:IO] == a[NO:IO])
    chk('name[%d] == %s' % (NN, NEW_PKG), onames[NN] == NEW_PKG)
    chk('name[%d] == %s' % (NN + 1, NEW_CLS), onames[NN + 1] == NEW_CLS)
    chk('ExportOffset == ImportOffset + 32*ImportCount', eo == io_ + 32 * ic)
    chk('PreloadOffset == ExportOffset + 2*96 + 12 (gap kept)', plo == eo + EXP_STRIDE * ec + (PLO - EO - EXP_STRIDE * EC))
    chk('TotalHeaderSize == PreloadOffset + 4*PreloadCount + tail', tot == plo + 4 * plc + (TOT - PLO - 4 * PLC))
    chk('Depends/SoftPkg/Searchable offsets == ExportEnd', i32(oa, Bo + 44) == i32(oa, Bo + 52) == i32(oa, Bo + 60) == eo + EXP_STRIDE * ec)
    chk('AssetRegistry offset == PreloadOffset-4', i32(oa, Bo + 136) == plo - 4)
    chk('vanilla import bytes unchanged', oa[io_:io_ + 32 * IC] == a[IO:IO + 32 * IC])
    pkg = struct.unpack_from('<8i', oa, io_ + 32 * IC)
    cls = struct.unpack_from('<8i', oa, io_ + 32 * (IC + 1))
    chk('import[%d] Package %s, outer 0' % (IC, NEW_PKG),
        onames[pkg[0]] == '/Script/CoreUObject' and onames[pkg[2]] == 'Package' and pkg[4] == 0 and onames[pkg[5]] == NEW_PKG)
    chk('import[%d] BlueprintGeneratedClass %s, outer %d' % (IC + 1, NEW_CLS, -(IC + 1)),
        onames[cls[0]] == '/Script/Engine' and onames[cls[2]] == 'BlueprintGeneratedClass'
        and cls[4] == -(IC + 1) and onames[cls[5]] == NEW_CLS)
    eall = [(i32(oa, eo + 96 * k + 76), i32(oa, eo + 96 * k + 80), i32(oa, eo + 96 * k + 84),
             i32(oa, eo + 96 * k + 88), i32(oa, eo + 96 * k + 92)) for k in range(ec)]
    ser = [i64(oa, eo + 96 * k + 28) for k in range(ec)]
    off = [i64(oa, eo + 96 * k + 36) for k in range(ec)]
    chk('export sizes %s == [%d, %d]' % (ser, X0['ser'], X1['ser'] + GROW), ser == [X0['ser'], X1['ser'] + GROW])
    chk('export SerialOffset chain %s' % off, off == [tot, tot + ser[0]])
    chk('export 1 CreateBefore count %d == %d' % (eall[1][2], X1['cb'] + 1), eall[1][2] == X1['cb'] + 1)
    chk('export fields FED/SB/SBC/CBC unchanged', eall == [(X0['fed'], X0['sb'], X0['cb'], X0['sbc'], X0['cbc']),
                                                           (X1['fed'], X1['sb'], X1['cb'] + 1, X1['sbc'], X1['cbc'])])
    for k in range(2):  # all export fields except SerialSize(28), SerialOffset(36), CreateBefore count(84) unchanged
        o, v = eo + 96 * k, EO + 96 * k
        chk('export %d entry fields unchanged except size/offset/CB' % k,
            oa[o:o + 28] == a[v:v + 28] and oa[o + 44:o + 84] == a[v + 44:v + 84] and oa[o + 88:o + 96] == a[v + 88:v + 96])
    pref = [i32(oa, plo + 4 * i) for i in range(plc)]
    want = PL[:PIDX] + [NEWREF] + PL[PIDX:]
    chk('preload == vanilla with %d inserted at index %d' % (NEWREF, PIDX), pref == want)
    bulk = i32(oa, Bo + 140)
    chk('BulkDataStart %d == TotalHeaderSize + sum(SerialSize)' % bulk, bulk == tot + sum(ser))
    chk('uexp length %d == sum(SerialSize) + 4 footer' % len(oe), len(oe) == sum(ser) + 4)

    # uexp: header idx set gains 24 (value count of header grows by one), value sits before idx 29
    idx, hend = hdr_idx(oe)
    chk('header idx %s == vanilla + [24]' % idx, idx == sorted(HDR_IDX + [IDX_DM]) and hend == HDR + 18)
    chk('header bytes 104..115 unchanged', oe[:HDR + 12] == e[:HDR + 12])
    ni = len(oe) - TAIL - 22             # == INS + GROW_HDR: value starts right before idx 29 value
    chk('DefaultMachines count 1 at inserted block (%d)' % ni, i32(oe, ni) == 1)
    chk('machine element struct 80 09 0c', oe[ni + 4:ni + 7] == b'\x80\x09\x0c')
    ref = i32(oe, ni + 7)
    chk('machine class ref %d -> import %s' % (ref, NEW_CLS), ref == NEWREF and -ref - 1 == IC + 1 and onames[cls[5]] == NEW_CLS)
    chk('machine transform 80 07 06 (height+rot omitted)', oe[ni + 11:ni + 14] == b'\x80\x07\x06')
    chk('machine X == %d' % MX, i32(oe, ni + 14) == MX)
    chk('machine Y == %d' % MY, i32(oe, ni + 18) == MY)
    chk('uexp new block == value(%d)' % NEWREF, oe[ni:ni + 22] == VAL)
    chk('uexp idx 29 + idx 37 + trailer + footer follow', oe[ni + 22:] == e[INS:])
    chk('uexp body between header and value unchanged', oe[HDR + 16:ni] == e[HDR + 14:INS])
    els, end, nxt = walk(oe, DM + GROW_HDR)
    chk('CONNECTOR array still count 1 at uexp %d, ref %d' % (DM + GROW_HDR, CONN_REF), len(els) == 1 and els[0] == els0[0])
    chk('CONNECTOR element is %s' % CONNECTOR, onames[struct.unpack_from('<8i', oa, io_ + 32 * conn_idx[0])[5]] == CONNECTOR)
    chk('connector walk end %d, next int32 == 20 (got end %d next %d)' % (404 + GROW_HDR, end, nxt), end == 404 + GROW_HDR and nxt == 20)
    diff = {q for q in range(NO) if oa[q] != a[q]}
    allowed = {q + i for q in OFF_FIELDS + [B, B + 32, B + 140, B + 156] for i in range(4)}
    chk('header bytes changed only at patched positions %s' % sorted(diff - allowed)[:8], diff <= allowed)
    print('RESULT ' + ('PASS' if not fail else 'FAIL %d' % len(fail)))
    return not fail


ok = verify(out_a, out_e)
print('uasset %d -> %d   uexp %d -> %d' % (len(a), len(out_a), len(e), len(out_e)))
if ok:
    open(BASE + '.uasset', 'wb').write(out_a)
    open(BASE + '.uexp', 'wb').write(out_e)
    for fn in ('BPO_BlueprintUnit.uasset', 'BPO_BlueprintUnit.uexp'):
        print(hashlib.sha256(open(os.path.join(sys.argv[1], fn), 'rb').read()).hexdigest(), fn)
sys.exit(0 if ok else 1)
