"""Exercise status validation and byte-based speed sampling without hardware."""
import pathlib
import subprocess
import tempfile
import time

root = pathlib.Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory() as directory:
    state = pathlib.Path(directory) / 'state'
    binary = pathlib.Path(directory) / 'ui'
    subprocess.run([
        'cc', '-std=c11', '-Wall', '-Wextra', '-Werror',
        f'-DSTATE="{state}"', '-Ibuild/recovery', '-I/usr/include/libdrm',
        'platform/recovery/ui.c', '-ldrm', '-lm', '-o', str(binary),
    ], cwd=root, check=True)

    def update(*args, valid=True):
        before = state.read_bytes() if state.exists() else None
        result = subprocess.run([str(binary), 'status', *map(str, args)])
        assert result.returncode == (0 if valid else 2), args
        if not valid:
            assert state.read_bytes() == before
        return state.read_text().splitlines()

    for mode in ['ready', 'preparing', 'stopping', 'complete', 'cancelled', 'error']:
        assert update(mode)[0] == mode
    update('backup', 0, 1000)
    time.sleep(.05)
    values = update('backup', 500, 1000)[4].split()
    assert values[:2] == ['500', '1000'] and float(values[3]) > 0
    assert float(update('backup', 500, 1000)[4].split()[3]) == 0
    assert float(update('backup', 0, 1000)[4].split()[3]) == 0
    assert float(update('flash', 500, 1000)[4].split()[3]) == 0
    update('verify', 1000, 1000)
    update('restore', 100, 0)  # Unknown total uses the spinner.
    update('backup', 2**64 - 1, 2**64 - 1)
    for args in [('backup', -1, 10), ('flash', 11, 10),
                 ('restore', '1x', 10), ('backup', 2**64, 2**64),
                 ('verify', 1), ('unknown',), ('progress', 101),
                 ('busy', 'newline\ntext')]:
        update(*args, valid=False)
    update('progress', 42, 'Checking display', 'Test only')
    update('ready')
    image = pathlib.Path(directory) / 'ready.ppm'
    subprocess.run([str(binary), 'preview', 'ready', str(image)], check=True)
    assert image.read_bytes().startswith(b'P6\n480 360\n255\n')
    # Long detail lines must not swallow the following progress counters.
    state.write_text('flash\n50\nFlashing rootfs\nPartition 4/5 - write + readback verification\n50 100 0 0\n')
    subprocess.run([str(binary), 'preview', 'state', str(image)], check=True)
    pixels = image.read_bytes().split(b'\n', 3)[3]
    def pixel(x, y): return pixels[(y * 480 + x) * 3:(y * 480 + x) * 3 + 3]
    assert pixel(60, 318) != pixel(400, 318), 'Expected a half-filled determinate progress bar'
    assert any(pixel(x, 292) != pixel(x, 280) for x in range(60, 420)), 'Expected the third status line'

print('Recovery status tests passed')
