"""Offline checks of EDID, memory reservations, LUT translation and release identity."""
import hashlib
import json
import re
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BUILD = Path(sys.argv[1]).resolve() if len(sys.argv)>1 else ROOT / 'build/hdmi_native_gc16_20260920'
PREVIOUS = ROOT / 'build/hdmi_du5_local_recovery_20260920/nand_release'
RTL = ROOT / 'c/p/Eink_controller_V1.0.srcs/sources_1/new'


def elf_segments(path):
    data = path.read_bytes()
    header = struct.unpack_from('<16sHHIIIIIHHHHHH', data)
    assert header[0][:6] == b'\x7fELF\x01\x01', 'Expected little-endian ELF32'
    regions = []
    for i in range(header[10]):
        ph = struct.unpack_from('<IIIIIIII', data, header[5] + i * header[9])
        if ph[0] == 1 and ph[5]:
            regions.append((ph[3], ph[3] + ph[5]))
    return regions


if __name__ == '__main__':
    memory = [(0x0E800000, 0x0EC00000), (0x0EC00000, 0x0F000000)]
    segments = elf_segments(PREVIOUS / 'frame_buffer_ddr15.elf')
    for start, end in segments:
        for a, b in memory:
            assert end <= a or start >= b, f'Application overlaps transition memory: {start:x}..{end:x}'
    assert 2560 * 1600 <= 4 * 1024 * 1024
    edid = (ROOT / 'build/tests/es120_edid_tb/edid.bin').read_bytes()
    assert len(edid) == 128 and sum(edid) % 256 == 0
    h = edid[56] | ((edid[58] >> 4) << 8)
    hb = edid[57] | ((edid[58] & 15) << 8)
    v = edid[59] | ((edid[61] >> 4) << 8)
    vb = edid[60] | ((edid[61] & 15) << 8)
    clock = int.from_bytes(edid[54:56], 'little') * 10000
    assert (h, v, clock) == (2560, 1600, 111930000)
    top = (RTL / 'eink_controller_es120mc1.v').read_text(encoding='utf-8-sig')
    assert '.DITHER_ENABLE(0), .NATIVE_GC16(1)' in top
    assert '.BOOT_CLEAR_CYCLES(3), .BOOT_CYCLE_MIN_CYCLES(SYS_CLK_FREQ * 3000000)' in top
    before = BUILD / 'source_before/rtl'
    for filename in ('clock_pll_es120mc1.v', 'frame_ctrl_es120mc1.v', 'data_mgr.v', 'adv7611_iic_manager.v'):
        assert (RTL / filename).read_bytes() == (before / filename).read_bytes(), filename
    # All generated ROM entries, including the two neutral tail phases.
    text = (RTL / 'gc16_lut_es120mc1.v').read_text()
    entries = [(int(i), int(v)) for i, v in re.findall(r"lut\[13'd(\d+)\] = 2'd(\d+);", text)]
    codes = bytes(int(line, 16) for line in (BUILD / 'gc16_reference.mem').read_text().splitlines())
    assert entries == list(enumerate(codes))
    assert len(codes) == 8192 and codes[7680:] == bytes(512)
    summary = {'edid': {'h': h, 'v': v, 'pixel_clock_hz': clock,
                       'refresh_hz': clock / ((h + hb) * (v + vb)), 'checksum': f'{edid[127]:02X}'},
               'transition_buffers': [[hex(a), hex(b)] for a, b in memory],
               'application_segments': [[hex(a), hex(b)] for a, b in segments],
               'native_lut_sha256': hashlib.sha256(codes).hexdigest()}
    (BUILD / 'offline_validation.json').write_text(json.dumps(summary, indent=2) + '\n')
    print('PASS native release: EDID, complete LUT, endpoint buffers, application non-overlap, retained panel protocol and receiver')
    print(json.dumps(summary, indent=2))
