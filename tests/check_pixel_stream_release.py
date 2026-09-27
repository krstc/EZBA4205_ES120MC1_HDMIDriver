"""Check the candidate against retained hardware/EDID and supplied waveform sources."""
import hashlib
import json
import re
from pathlib import Path

from check_gc16_release import elf_segments
from generate_es120_gc16 import load_table

ROOT = Path(__file__).resolve().parents[1]
RTL = ROOT / 'c/p/Eink_controller_V1.0.srcs/sources_1/new'
BUILD = ROOT / 'build/hdmi_pixel_stream_20260921'
PREVIOUS = ROOT / 'build/hdmi_hybrid_gc16_20260920/nand_release'
before = BUILD / 'source_before/rtl'
for name in ('clock_pll_es120mc1.v', 'frame_ctrl_es120mc1.v', 'data_mgr.v',
             'config_reg_es120mc1.v', 'adv7611_iic_manager.v', 'hdmi_input_es120mc1.v'):
    assert (RTL / name).read_bytes() == (before / name).read_bytes(), name

edid = (ROOT / 'build/tests/es120_edid_tb/edid.bin').read_bytes()
assert len(edid) == 128 and sum(edid) % 256 == 0
h = edid[56] | ((edid[58] >> 4) << 8)
hb = edid[57] | ((edid[58] & 15) << 8)
v = edid[59] | ((edid[61] >> 4) << 8)
vb = edid[60] | ((edid[61] & 15) << 8)
clock = int.from_bytes(edid[54:56], 'little') * 10000
assert (h, v, h+hb, v+vb, clock) == (2560, 1600, 2720, 1646, 111930000)
assert edid == (PREVIOUS / 'edid.bin').read_bytes()

core = (RTL / 'frame_stream_es120mc1.v').read_text()
addresses = {n: int(re.search(rf"{n}=32'h([0-9A-Fa-f]+)", core)[1], 16)
             for n in ('STATE0', 'STATE1', 'DATA0', 'DATA1')}
regions = [(a, a+h*v*(2 if name.startswith('STATE') else 3/4)) for name, a in addresses.items()]
regions = [(a, int(b)) for a, b in regions]
for i, (a, b) in enumerate(regions):
    assert 0 < a < b < 0x10000000
    for c, d in regions[:i] + elf_segments(PREVIOUS / 'frame_buffer_ddr15.elf'):
        assert b <= c or a >= d, (hex(a), hex(b), hex(c), hex(d))

table = load_table()
rom = (RTL / 'gc16_lut_es120mc1.v').read_text()
entries = [(int(i), int(code)) for i, code in re.findall(r"lut\[13'd(\d+)\] = 2'd(\d+);", rom)]
reference = bytes(int(line, 16) for line in (ROOT / 'build/hdmi_native_gc16_20260920/gc16_reference.mem').read_text().splitlines())
assert entries == list(enumerate(reference)) and len(reference) == 8192
for phase in range(30):
    for target in range(16):
        for old in range(16):
            assert reference[phase*256+target*16+old] == (table[phase][target][old//4] >> (6-2*(old%4))) & 3
assert reference[7680:] == bytes(512)
assert (RTL / 'gc16_lut_es120mc1.v').read_bytes() == (before / 'gc16_lut_es120mc1.v').read_bytes()

summary = {
    'edid': {'resolution': [h, v], 'clock_hz': clock, 'refresh_hz': clock/((h+hb)*(v+vb)),
             'sha256': hashlib.sha256(edid).hexdigest()},
    'panel_scan_hz': (50e6*13/14.75)/(362*1623),
    'nominal_packet_hz': (50e6*13/14.75)/(362*1623*3),
    'buffers': [[hex(a), hex(b)] for a, b in regions],
    'gc16_sha256': hashlib.sha256(reference).hexdigest(),
    'runtime_ddr_MB_s_at_25hz': {'state_read': h*v*2*25/1e6, 'state_write': h*v*2*25/1e6,
                                'drive_write': h*v*.75*25/1e6, 'drive_read': h*v*.25*75/1e6},
    'hardware_verified': False,
}
(BUILD / 'offline_validation.json').write_text(json.dumps(summary, indent=2)+'\n')
print('PASS stream release: EDID byte identity, 2560x1600/25Hz, native LUT, nonoverlapping DDR/ELF, retained panel timing and receiver')
print(json.dumps(summary, indent=2))
