"""Run inside the toolchain container. Package the experimental DA RAM payload."""
from pathlib import Path
import hashlib
import json
import struct

root = Path(__file__).resolve().parents[2]
out = root / 'build/recovery'
entry = (out / 'entry.bin').read_bytes()
dtb = (out / 'kernel/arch/arm/boot/dts/mediatek/mt6582-innioasis-y2.dtb').read_bytes()
kernel = (out / 'kernel/arch/arm/boot/zImage').read_bytes()
assert len(entry) <= 0x1000 and len(dtb) <= 0x7000
assert dtb[:4] == bytes.fromhex('d00dfeed')
assert kernel[0x24:0x28] == bytes.fromhex('18286f01'), 'Not an ARM zImage'
payload = bytearray(0x8000)
payload[:len(entry)] = entry
payload[0x1000:0x1000 + len(dtb)] = dtb
payload += kernel
payload += bytes(256)  # vendor stage 1 hashes length - 256 bytes
assert len(payload) <= 32 * 1024 * 1024

source = root / 'platform/firmware/stock/rockbox-MTK_AllInOne_DA.bin'
da = bytearray(source.read_bytes())
# entry.S calls this version's initialized transport vtable for a USB marker.
assert hashlib.sha256(da).hexdigest() == '4729b77976508708a541039a807f3203f68a37e91ebbc832ac7db70b4ea6d832', 'Unrecognized DA transport ABI' 
entries = [0x6c + i * 0xdc for i in range(struct.unpack_from('<I', da, 0x68)[0])
           if struct.unpack_from('<H', da, 0x6c + i * 0xdc + 2)[0] == 0x6582]
assert len(entries) == 1
entry_at = entries[0]
first = struct.unpack_from('<5I', da, entry_at + 40)
second = struct.unpack_from('<5I', da, entry_at + 60)
assert first[2] == 0x200000 and second[2] == 0x80000000 and second[4] == 256
old_hash = hashlib.sha1(da[second[0]:second[0] + second[1] - 256]).digest()
first_bytes = da[first[0]:first[0] + first[1]]
assert first_bytes.count(old_hash) == 1, 'Unrecognized vendor hash table'
hash_at = first[0] + first_bytes.index(old_hash)
da[hash_at:hash_at + 20] = hashlib.sha1(payload[:-256]).digest()
(out / 'payload.bin').write_bytes(payload)
(out / 'ramboot-DA.bin').write_bytes(da)
report = dict(payload_bytes=len(payload), load_address='0x80000000',
              kernel_address='0x80008000', dtb_address='0x80001000',
              stage1_hash_offset=hex(hash_at - first[0]),
              payload_sha256=hashlib.sha256(payload).hexdigest(),
              vendor_da_sha256=hashlib.sha256(source.read_bytes()).hexdigest())
(out / 'manifest.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
