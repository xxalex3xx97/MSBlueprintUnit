"""Dev dump of a cooked .uasset/.uexp pair: header offsets, names, imports, exports, preload deps, raw uexp.
Usage: python -I dump_uasset.py <path without extension>   (e.g. src\\RSC_MiningLaser)
"""
import struct, sys
S = sys.argv[1]
a = open(S + '.uasset', 'rb').read(); e = open(S + '.uexp', 'rb').read()
u = lambda b, q: struct.unpack_from('<i', b, q)[0]
# B = NameCount offset = 56 + FolderName FString (len @52 incl NUL) + 4 (PackageFlags). ML B=96, CS B=103.
B = 60 + u(a, 52)
q8 = lambda b, q: struct.unpack_from('<q', b, q)[0]
print('uasset', len(a), 'uexp', len(e), 'B', B)
H = [44] + [B + k for k in (0, 4, 12, 24, 28, 32, 36, 136, 140, 156, 160)]
print('hdr i32 @' + ','.join(map(str, H)) + ':', [u(a, x) for x in H])
no = u(a, B + 4)
print('header i32 with value in [100, %d]:' % (len(a) + len(e)), [(x, u(a, x)) for x in range(0, no - 3) if 100 <= u(a, x) <= len(a) + len(e)])
nn = u(a, B); p = no; names = []
for i in range(nn):
    n = u(a, p); names.append(a[p + 4:p + 3 + n].decode('latin1')); p += 8 + n
print('names end at', p, '(ImportOffset %d)' % u(a, B + 36))
for i, n in enumerate(names): print('name', i, n)
ic, io_ = u(a, B + 32), u(a, B + 36)
for i in range(ic):
    t = struct.unpack_from('<8i', a, io_ + 32 * i)
    print('import', i, t, '|', names[t[0]], names[t[2]], names[t[5]])
ec, eo = u(a, B + 24), u(a, B + 28)
for i in range(ec):
    b = eo + 104 * i
    print('export', i, struct.unpack_from('<8i', a, b), 'ser', q8(a, b + 28), 'off', q8(a, b + 36), 'tail', struct.unpack_from('<14i', a, b + 44))
plc, plo = u(a, B + 156), u(a, B + 160)
print('preload', plc, 'at', plo, [u(a, plo + 4 * i) for i in range(plc)])
print('tail bytes after preload:', plo + 4 * plc, 'to', len(a), a[plo + 4 * plc:].hex())
print('uexp hex:')
for i in range(0, len(e), 16):
    print('%04x' % i, e[i:i + 16].hex(' ', 4), ' ', ''.join(chr(c) if 32 <= c < 127 else '.' for c in e[i:i + 16]))
print('uexp as i32:', [(i, u(e, i)) for i in range(0, len(e) - 3, 4)])
