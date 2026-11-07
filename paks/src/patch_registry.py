# ponytail: patch vanilla DAT_BuildingBlockRegistry (uasset header + uexp array) to add block entries.
# Usage: python -I patch_registry.py <K: 1|2|3> <VARIANT: A|B> <OUT_DIR>
#   K=1      bench only (original build, must reproduce the k=1 output byte-for-byte)
#   K=2 A    bench + Mining Unit both in the Functional Blocks array (array 19 -> 21)
#   K=2 B    bench still imported/preloaded (old saves load) but REMOVED from the array; Mining Unit added (array 19 -> 20)
#   K=3 B    as K=2 B + Blueprint Unit added to the array (array 19 -> 21)
# Entry j adds: package import (IC+2j), class import (IC+2j+1, outer = package import), 2 names, 1 preload ref -(IC+2j+2).
# Header offsets are patched by value (same approach as the original script). verify() re-parses the output and asserts the layout.
import struct
import sys
import os
import hashlib

K = int(sys.argv[1])
VAR = sys.argv[2]
OUT = sys.argv[3]
MODS_ROOT = os.environ.get('MS_MODS_ROOT', 'F:/MSDemoMods')  # repo root, holds legacy/ (vanilla source)
S = MODS_ROOT + '/legacy/MainSequence/Content/Data/DAT_BuildingBlockRegistry'
BLK = '/Game/Blueprints/BuildingBlocks/'

# vanilla layout (positions in the .uasset header)
NN, NO, IC, IO, EO = 251, 277, 245, 10686, 18526   # name count/offset, import count/offset, export offset
PLO, PLC = 18630, 83                              # preload dependency offset/count
VANILLA_EXPORT_SIZE = 746                         # export 0 SerialSize before array growth
VANILLA_ARRAY = 19                                # Functional Blocks element count
VANILLA_HEADER = 19021                            # = vanilla TotalHeaderSize = uexp start

# entries: 0 = old bench (kept for old saves), 1 = Mining Unit, 2 = Blueprint Unit
ENT = [(BLK + 'BPO_MiningBenchBlock', 'BPO_MiningBenchBlock_C'),
       (BLK + 'BPO_MinerModuleBlock', 'BPO_MinerModuleBlock_C'),
       (BLK + 'BPO_BlueprintUnit', 'BPO_BlueprintUnit_C')]
# which entries appear in the Functional Blocks array (uexp), by entry index
ARR = {'1A': [0], '2A': [0, 1], '2B': [1], '3B': [1, 2]}[str(K) + VAR]
ents = ENT[:K]

a = open(S + '.uasset', 'rb').read()
e = open(S + '.uexp', 'rb').read()

# read vanilla name table
names = []
p = NO
for i in range(NN):
    n = struct.unpack_from('<i', a, p)[0]
    names.append(a[p + 4:p + 3 + n].decode())
    p += 8 + n
assert p == IO


def fs(s):
    b = s.encode() + b'\0'
    return struct.pack('<i', len(b)) + b + b'\0\0\0\0'


ix = lambda s: names.index(s)
newnames = b''.join(fs(pk) + fs(cl) for pk, cl in ents)
A = len(newnames)
imp = b''
for j in range(K):
    imp += struct.pack('<8i', ix('/Script/CoreUObject'), 0, ix('Package'), 0, 0, NN + 2 * j, 0, 0)
    imp += struct.pack('<8i', ix('/Script/Engine'), 0, ix('BlueprintGeneratedClass'), 0, -(IC + 2 * j + 1), NN + 2 * j + 1, 0, 0)
P3 = PLO + 4 * 81                                 # end of export 0 serialization-before deps (81 vanilla), 2 create deps follow
pre = b''.join(struct.pack('<i', -(IC + 2 * j + 2)) for j in range(K))
ins = [(IO, A), (EO, len(imp)), (P3, 4 * K)]


def sh(v):
    return v + sum(l for pos, l in ins if v >= pos)


# header: shift known offset values (byte-scan, as the original script did)
offs = {IO, EO, 18622, 18626, PLO, VANILLA_HEADER, 19767}
h = bytearray(a[:NO])
for q in range(44, NO - 3):
    v = struct.unpack_from('<i', h, q)[0]
    if v in offs:
        # BulkDataStart (19767) = header + export size, so it also grows with the array
        struct.pack_into('<i', h, q, sh(v) + (4 * len(ARR) if v == 19767 else 0))


def setat(buf, val, new, after=0):
    for q in range(after, len(buf) - 3):
        if struct.unpack_from('<i', buf, q)[0] == val:
            struct.pack_into('<i', buf, q, new)
            return q
    raise Exception(val)


setat(h, NN, NN + 2 * K, 60)       # NameCount (generation NameCount at 185 stays vanilla 251, as in the k=1 build)
setat(h, IC, IC + 2 * K, 60)       # ImportCount
setat(h, PLC, PLC + K, 60)         # PreloadDependencyCount
h = bytes(h)

nm = a[NO:IO]
im = a[IO:EO]
ex = bytearray(a[EO:PLO])          # one export entry (104 bytes)
pl = a[PLO:P3]
pl2 = a[P3:]
struct.pack_into('<q', ex, 28, VANILLA_EXPORT_SIZE + 4 * len(ARR))   # SerialSize
struct.pack_into('<q', ex, 36, sh(VANILLA_HEADER))                  # SerialOffset = new header size
assert struct.unpack_from('<i', ex, 84)[0] == 81                    # SerializationBefore deps count
struct.pack_into('<i', ex, 84, 81 + K)
out = h + nm + newnames + im + imp + bytes(ex) + pl + pre + pl2

# uexp: Functional Blocks array (count, then refs). New refs go right after the vanilla -80 element.
u = bytearray(e)
k0 = e.index(b'Functional Blocks\0') + len(b'Functional Blocks\0')
assert struct.unpack_from('<i', e, k0)[0] == VANILLA_ARRAY
w = e.index(struct.pack('<i', -80), k0)
assert w - k0 < 4 + 4 * VANILLA_ARRAY
u[w + 4:w + 4] = b''.join(struct.pack('<i', -(IC + 2 * j + 2)) for j in ARR)
struct.pack_into('<i', u, k0, VANILLA_ARRAY + len(ARR))


# ---- verify: parse the OUTPUT bytes and assert the layout ----
def verify(oa, oe):
    fail = []

    def chk(label, cond):
        print(('ok   ' if cond else 'FAIL ') + label)
        if not cond:
            fail.append(label)

    u32 = lambda buf, q: struct.unpack_from('<i', buf, q)[0]
    total = u32(oa, 44)
    chk('uasset length %d == TotalHeaderSize %d' % (len(oa), total), len(oa) == total)
    nn, no, ic, io_ = u32(oa, 97), u32(oa, 101), u32(oa, 129), u32(oa, 133)
    ec, eo, plc, plo = u32(oa, 121), u32(oa, 125), u32(oa, 253), u32(oa, 257)
    chk('NameCount %d == %d' % (nn, NN + 2 * K), nn == NN + 2 * K)
    chk('ExportCount 1', ec == 1)
    chk('ImportCount %d == %d' % (ic, IC + 2 * K), ic == IC + 2 * K)
    chk('PreloadCount %d == %d' % (plc, PLC + K), plc == PLC + K)
    chk('NameOffset == %d' % NO, no == NO)
    onames, p = [], no
    for i in range(nn):
        n = u32(oa, p)
        onames.append(oa[p + 4:p + 3 + n].decode())
        p += 8 + n
    chk('name table ends at ImportOffset (%d)' % io_, p == io_)
    for j, (pk, cl) in enumerate(ents):
        chk('name[%d] == %s' % (NN + 2 * j, pk), onames[NN + 2 * j] == pk)
        chk('name[%d] == %s' % (NN + 2 * j + 1, cl), onames[NN + 2 * j + 1] == cl)
    chk('ExportOffset == ImportOffset + 32*ImportCount', eo == io_ + 32 * ic)
    chk('PreloadOffset == ExportOffset + 104', plo == eo + 104)
    chk('TotalHeaderSize == PreloadOffset + 4*PreloadCount + vanilla tail (%d)' % (VANILLA_HEADER - PLO - 4 * PLC),
        total == plo + 4 * plc + (VANILLA_HEADER - PLO - 4 * PLC))
    for j in range(K):
        q = io_ + 32 * (IC + 2 * j)
        pkg = struct.unpack_from('<8i', oa, q)
        cls = struct.unpack_from('<8i', oa, q + 32)
        chk('import[%d] package: name %d, outer 0' % (IC + 2 * j, NN + 2 * j), pkg[5] == NN + 2 * j and pkg[4] == 0)
        chk('import[%d] class: name %d, outer -(%d)' % (IC + 2 * j + 1, NN + 2 * j + 1, IC + 2 * j + 1),
            cls[5] == NN + 2 * j + 1 and cls[4] == -(IC + 2 * j + 1))
        chk('import[%d] ClassName == BlueprintGeneratedClass' % (IC + 2 * j + 1),
            onames[cls[2]] == 'BlueprintGeneratedClass')
    chk('vanilla import bytes unchanged', oa[io_:io_ + 32 * IC] == a[IO:IO + 32 * IC])
    ser, off = struct.unpack_from('<q', oa, eo + 28)[0], struct.unpack_from('<q', oa, eo + 36)[0]
    chk('export SerialSize %d == %d' % (ser, VANILLA_EXPORT_SIZE + 4 * len(ARR)), ser == VANILLA_EXPORT_SIZE + 4 * len(ARR))
    chk('export SerialOffset %d == TotalHeaderSize' % off, off == total)
    chk('export SerializationBefore count == %d' % (81 + K), u32(oa, eo + 84) == 81 + K)
    van_pl = [u32(a, PLO + 4 * i) for i in range(PLC)]
    pref = [u32(oa, plo + 4 * i) for i in range(PLC + K)]
    chk('preload: vanilla 81 refs kept', pref[:81] == van_pl[:81])
    chk('preload: new refs == %s' % [-(IC + 2 * j + 2) for j in range(K)], pref[81:81 + K] == [-(IC + 2 * j + 2) for j in range(K)])
    chk('preload: vanilla create refs kept', pref[81 + K:] == van_pl[81:])
    bulk = u32(oa, 237)
    chk('BulkDataStart %d == TotalHeaderSize + SerialSize %d' % (bulk, total + ser), bulk == total + ser)
    chk('uexp length %d == SerialSize + 4 footer' % len(oe), len(oe) == ser + 4)
    ka = oe.index(b'Functional Blocks\0') + len(b'Functional Blocks\0')
    cnt = u32(oe, ka)
    chk('array count %d == %d' % (cnt, VANILLA_ARRAY + len(ARR)), cnt == VANILLA_ARRAY + len(ARR))
    refs = [u32(oe, ka + 4 + 4 * i) for i in range(cnt)]
    van = [u32(e, k0 + 4 + 4 * i) for i in range(VANILLA_ARRAY)]
    for j in range(K):
        if j in ARR:
            chk('array has ref -(%d) (entry %d)' % (IC + 2 * j + 2, j), -(IC + 2 * j + 2) in refs)
        else:
            chk('array has no ref -(%d) (entry %d removed)' % (IC + 2 * j + 2, j), -(IC + 2 * j + 2) not in refs)
    chk('array vanilla refs kept in order', [r for r in refs if r in van] == van)
    print('RESULT ' + ('PASS' if not fail else 'FAIL %d' % len(fail)))
    return not fail


os.makedirs(OUT, exist_ok=True)
open(os.path.join(OUT, 'DAT_BuildingBlockRegistry.uasset'), 'wb').write(out)
open(os.path.join(OUT, 'DAT_BuildingBlockRegistry.uexp'), 'wb').write(bytes(u))
print('K=%d VAR=%s array=%s  names+%d imports+%d preload+%d' % (K, VAR, ARR, 2 * K, 2 * K, K))
print('uasset %d -> %d   uexp %d -> %d' % (len(a), len(out), len(e), len(u)))
for fn in ['DAT_BuildingBlockRegistry.uasset', 'DAT_BuildingBlockRegistry.uexp']:
    print(hashlib.sha256(open(os.path.join(OUT, fn), 'rb').read()).hexdigest(), fn)
sys.exit(0 if verify(out, bytes(u)) else 1)
