#!/usr/bin/env python3
# Usage: optional-version.py FILE VERSION_NAME
#
# Marks every required-version entry named VERSION_NAME in FILE as optional.
# A library lists, for each library it links, the version labels it needs
# from it (for example OPENSSL_3.0.0 from libcrypto). The loader refuses to
# load the library if one of those labels is missing, even when no function
# uses it any more. Marking the entry optional (the VER_FLG_WEAK flag) makes
# the loader accept a library whose functions were moved to a newer library
# version that no longer has the label.
#
# This is only safe once no function in FILE still uses VERSION_NAME. Clear
# the label from each function first (patchelf --clear-symbol-version). The
# script checks this and refuses, naming the functions, if any still carry
# the label: such a function would fail on the device the first time it is
# called.
#
# Works on 64-bit little-endian ELF files only. Exits non-zero if FILE is not
# one, if no entry matched, or if a function still uses the label, so an
# unexpected input fails the build instead of shipping a broken library.
import struct, sys

if len(sys.argv) != 3:
    sys.exit('usage: optional-version.py FILE VERSION_NAME')
path, want = sys.argv[1], sys.argv[2].encode()
data = bytearray(open(path, 'rb').read())
# ELF header: magic, then class (2 = 64-bit) and byte order (1 = little-endian).
if data[0:4] != b'\x7fELF' or data[4] != 2 or data[5] != 1:
    sys.exit('%s: not a 64-bit little-endian ELF file' % path)
shoff, = struct.unpack_from('<Q', data, 0x28)
shentsize, shnum = struct.unpack_from('<HH', data, 0x3a)
secs = [struct.unpack_from('<IIQQQQIIQQ', data, shoff + i * shentsize) for i in range(shnum)]
changed = 0
indices = set()                    # version numbers the matched entries stand for
for name, typ, flags, addr, off, size, link, info, align, entsize in secs:
    if typ != 0x6ffffffe:          # SHT_GNU_verneed
        continue
    stroff = secs[link][4]
    ent = off
    for _ in range(info):
        vn_version, vn_cnt, vn_file, vn_aux, vn_next = struct.unpack_from('<HHIII', data, ent)
        aux = ent + vn_aux
        for _ in range(vn_cnt):
            vna_hash, vna_flags, vna_other, vna_name, vna_next = struct.unpack_from('<IHHII', data, aux)
            s = data[stroff + vna_name:data.index(0, stroff + vna_name)]
            if s == want:
                struct.pack_into('<H', data, aux + 4, vna_flags | 0x2)
                indices.add(vna_other & 0x7fff)
                changed += 1
            aux += vna_next
        ent += vn_next
if changed == 0:
    sys.exit('%s: no required-version entry named %s found' % (path, sys.argv[2]))

# Each function's version number is in the version table, one 2-byte entry
# per function, in the same order as the function table it links to.
still = []
for name, typ, flags, addr, off, size, link, info, align, entsize in secs:
    if typ != 0x6fffffff:          # SHT_GNU_versym
        continue
    symoff, symlink = secs[link][4], secs[link][6]
    stroff = secs[symlink][4]
    for i in range(size // 2):
        ver, = struct.unpack_from('<H', data, off + 2 * i)
        if ver & 0x7fff in indices:
            st_name, = struct.unpack_from('<I', data, symoff + 24 * i)
            still.append(data[stroff + st_name:data.index(0, stroff + st_name)].decode())
if still:
    sys.exit('%s: functions still use %s, clear their label first: %s'
             % (path, sys.argv[2], ' '.join(still)))

open(path, 'wb').write(data)
print(path, 'entries marked optional:', changed)
