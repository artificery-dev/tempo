"""Real service protocol tests against sparse temporary storage images."""
import pathlib, subprocess, tempfile, struct, zlib, os
HEADER=struct.Struct('<8sIIQQIIII')
root=pathlib.Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory() as directory:
    d=pathlib.Path(directory)
    images=[d/f'disk{i}' for i in range(3)]
    original=bytes(range(256))*4096
    for image in images: image.write_bytes(original*2)
    binary=d/'service'
    rootfs=d/'rootfs'; rootfs.mkdir()
    subprocess.run(['cc','-D_FILE_OFFSET_BITS=64',f'-DSTATE="{d}/state"','-std=c11','-O2','-Wall','-Wextra','-Werror',str(root/'platform/recovery/transfer.c'),'-o',str(binary)],check=True)
    p=subprocess.Popen([str(binary),'--test-stdio',*map(str,images)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,env={**os.environ,'TEMPO_RECOVERY_TEST_ROOTFS':str(rootfs)})
    def exact(n):
        result=b''
        while len(result)<n:
            piece=p.stdout.read(n-len(result));assert piece
            result+=piece
        return result
    def command(op,offset=0,length=0,data=b'',region=0,flags=0,valid=True,bad_crc=False):
        p.stdin.write(HEADER.pack(b'TEMPREC1',op,0,offset,length,len(data),(zlib.crc32(data)^bad_crc),region,flags)+data);p.stdin.flush()
        h=HEADER.unpack(exact(48));payload=exact(h[5]);assert h[0]==b'TEMPREC1' and h[1]==op|0x80000000
        assert h[2]==(0 if valid else 1),payload
        assert zlib.crc32(payload)==h[6]
        return h,payload
    try:
        assert b'"version":1' in command(1)[1]
        assert b'"context":true' in command(1)[1]
        command(9,data=b'Checking BOOTIMG\nPartition 1/9 - comparing saved data')
        command(2,length=1048576)
        assert (d/'state').read_text().splitlines()[2:4] == ['Checking BOOTIMG', 'Partition 1/9 - comparing saved data']
        assert command(4,length=1048576)[1]==original
        h,_=command(6,offset=1048576);assert h[3]==1048576
        command(7)
        # Sync and readback-verified writes alter only the declared range.
        command(9,data=b'Flashing RECOVERY\nPartition 2/9 - write + readback verification')
        command(3,offset=512,length=1024,flags=2)
        assert (d/'state').read_text().splitlines()[2] == 'Flashing RECOVERY'
        command(5,offset=512,length=1024,data=b'Z'*1024)
        command(7)
        assert images[0].read_bytes()==original[:512]+b'Z'*1024+(original*2)[1536:]
        # Range overflow, boot-region authorization, checksum and ordering.
        command(2,offset=2**64-512,length=1024,valid=False)
        command(3,length=512,region=1,valid=False)
        # BOOT2 is writable without granting permission to flash the preloader.
        command(3,length=512,region=2,flags=2)
        command(5,length=512,data=b'B'*512,region=2)
        command(7)
        assert images[2].read_bytes()==b'B'*512+(original*2)[512:]
        command(3,length=512,region=1,flags=3)
        command(5,length=512,data=b'P'*512,region=1)
        command(7)
        assert images[1].read_bytes()==b'P'*512+(original*2)[512:]
        # Fill operations preserve boundaries and use the same readback gate.
        command(10,length=512,data=b'\0'*4,valid=False)
        command(3,offset=512,length=1024,flags=2)
        command(10,offset=512,length=512,data=b'ABCD')
        command(10,offset=1024,length=512,data=b'\0'*4)
        command(7)
        assert images[0].read_bytes()[512:1536] == b'ABCD'*128+b'\0'*512
        command(3,length=512,flags=2)
        command(10,length=512,data=b'Z',valid=False)
        command(11)  # Test mode acknowledges without rebooting the host.
        before=images[0].read_bytes()
        command(3,length=512)
        command(5,length=512,data=b'X'*512,bad_crc=True,valid=False)
        assert images[0].read_bytes()==before
        command(2,length=1024)
        command(4,offset=512,length=512,valid=False)
        command(2,length=1024)
        command(7,valid=False)
        command(2,length=1024)
        command(8)
        command(8)  # Repeated cancellation is safe after a failed session.
        command(1)
        command(3,length=512,flags=2)
        command(5,length=512,data=before[:512])
        command(7)
        command(1)  # A protocol failure must not poison the next operation.
        # Device setup lands in the root filesystem, private to root; the
        # clock takes only plausible times. Neither runs during a transfer.
        assert b'"setup":true' in command(1)[1] and b'"time":true' in command(1)[1]
        command(9,data=b'Writing device setup\nSaving first-run choices')
        command(12,offset=0x5180000,length=1<<20,data=b'{"hostname":"y2"}')
        setup=rootfs/'first-run-config.json'
        assert setup.read_bytes()==b'{"hostname":"y2"}' and setup.stat().st_mode&0o777==0o600
        assert (d/'state').read_text().splitlines()[2]=='Device setup saved'
        command(12,offset=0x5180000,length=1<<20,valid=False)
        command(12,offset=0x5180000,length=1<<20,data=b'{"a":"\0"}',valid=False)
        command(12,offset=0x5180000,length=1<<20,data=b'{}',region=1,valid=False)
        command(12,offset=100,length=1<<20,data=b'{}',valid=False)
        command(12,offset=0x5180000,length=0,data=b'{}',valid=False)
        command(2,length=1024)
        command(12,offset=0x5180000,length=1<<20,data=b'{}',valid=False)
        command(8)
        assert setup.read_bytes()==b'{"hostname":"y2"}'
        command(13,offset=1_700_000_000)
        command(13,offset=100,valid=False)
        command(13,offset=1_700_000_000,length=512,valid=False)
        command(13,offset=1_700_000_000,data=b'x',valid=False)
        command(1)
        # Partial stream must never be accepted as a completed write.
        command(3,length=512)
        p.stdin.write(HEADER.pack(b'TEMPREC1',5,0,0,512,512,zlib.crc32(b'Q'*512),0,0)+b'Q'*100)
        p.stdin.close();assert p.wait(timeout=5)==0
        assert images[0].read_bytes()==before
    finally:
        if p.poll() is None:p.kill();p.wait()
print('Recovery transfer protocol tests passed')
