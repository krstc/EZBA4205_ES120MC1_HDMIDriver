"""Offline checks for the spatial-dither / binary-DU5 candidate."""
import hashlib
import json
import re
from pathlib import Path

from check_gc16_release import elf_segments
from generate_es120_gc16 import load_table

ROOT = Path(__file__).resolve().parents[1]
RTL = ROOT / 'c/p/Eink_controller_V1.0.srcs/sources_1/new'
BUILD = ROOT / 'build/hdmi_spatial_du5_20260921'
PREVIOUS = ROOT / 'build/hdmi_pixel_stream_20260921/nand_release'
BEFORE = BUILD / 'source_before/rtl'

# Timing, receiver, and EDID logic stay byte-identical to the last 25 Hz
# candidate. The HDMI pixel conversion is intentionally changed in this one.
for name in ('clock_pll_es120mc1.v', 'frame_ctrl_es120mc1.v', 'data_mgr.v',
             'config_reg_es120mc1.v', 'adv7611_iic_manager.v'):
    assert (RTL / name).read_bytes() == (BEFORE / name).read_bytes(), name

top = (RTL / 'eink_controller_es120mc1.v').read_text()
assert '.DITHER_ENABLE(1), .NATIVE_GC16(0), .VIDEO_LEVELS_ENABLE(1), .NATIVE_LIGHTEN(0)' in top
assert '.USE_NATIVE_GC16(0)' in top
assert re.search(r'display_mgr_es120mc1 #\([\s\S]*?\.NATIVE_GC16\(0\)', top)
assert '.NATIVE_GC16(0),' in top

hdmi = (RTL / 'hdmi_input_es120mc1.v').read_text()
assert 'wire [7:0] dither_rank256 = blue_noise_rank(dither_address_s2);' in hdmi
assert 'dither_level_s2 > dither_rank256' in hdmi

step = (RTL / 'pixel_step_es120mc1.v').read_text()
assert 'parameter ENABLE_NATIVE_GC16 = 1' in step
assert 'if(ENABLE_NATIVE_GC16 &&' in step
manager = (RTL / 'stream_manager_es120mc1.v').read_text()
assert 'refine<=0;' in manager

edid = (ROOT / 'build/tests/es120_edid_tb/edid.bin').read_bytes()
assert len(edid) == 128 and sum(edid) % 256 == 0
h = edid[56] | ((edid[58] >> 4) << 8)
hb = edid[57] | ((edid[58] & 15) << 8)
v = edid[59] | ((edid[61] >> 4) << 8)
vb = edid[60] | ((edid[61] & 15) << 8)
clock = int.from_bytes(edid[54:56], 'little') * 10000
assert (h, v, h + hb, v + vb, clock) == (2560, 1600, 2720, 1646, 111930000)
assert edid == (PREVIOUS / 'edid.bin').read_bytes()

core = (RTL / 'frame_stream_es120mc1.v').read_text()
addresses = {n: int(re.search(rf"{n}=32'h([0-9A-Fa-f]+)", core)[1], 16)
             for n in ('STATE0', 'STATE1', 'DATA0', 'DATA1')}
regions = []
for name, address in addresses.items():
    size = h * v * (2 if name.startswith('STATE') else 3 / 4)
    regions.append((address, int(address + size), name))
elf = elf_segments(PREVIOUS / 'frame_buffer_ddr15.elf')
for start, end, name in regions:
    assert 0 < start < end < 0x10000000
    for other_start, other_end in [(a, b) for a, b, _ in regions if _ != name] + elf:
        assert end <= other_start or start >= other_end, (name, hex(start), hex(end))

# Retain the verified LUT as a library artifact, but make sure this top-level
# candidate does not select it for active video packets.
table = load_table()
rom = (RTL / 'gc16_lut_es120mc1.v').read_text()
entries = [(int(i), int(code)) for i, code in re.findall(r"lut\[13'd(\d+)\] = 2'd(\d+);", rom)]
reference = bytes(int(line, 16) for line in (ROOT / 'build/hdmi_native_gc16_20260920/gc16_reference.mem').read_text().splitlines())
assert entries == list(enumerate(reference)) and len(reference) == 8192
for phase in range(30):
    for target in range(16):
        for old in range(16):
            assert reference[phase * 256 + target * 16 + old] == (table[phase][target][old // 4] >> (6 - 2 * (old % 4))) & 3
assert (RTL / 'gc16_lut_es120mc1.v').read_bytes() == (BEFORE / 'gc16_lut_es120mc1.v').read_bytes()

summary = {
    'edid': {'resolution': [h, v], 'clock_hz': clock,
             'refresh_hz': clock / ((h + hb) * (v + vb)),
             'sha256': hashlib.sha256(edid).hexdigest()},
    'input_dither': '16x16 blue-noise threshold, binary output, studio expansion + contrast tone map',
    'active_waveform': 'DU5 per-pixel state with reversal cancellation; native GC16 disabled',
    'status_hold_seconds': 2,
    'buffers': [[name, hex(a), hex(b)] for a, b, name in regions],
    'hardware_verified': False,
}
(BUILD / 'offline_validation.json').write_text(json.dumps(summary, indent=2) + '\n')
print('PASS spatial DU5 release: EDID identity, 2560x1600/25Hz, 16x16 blue-noise path, no active native GC16, DDR/ELF separation')
print(json.dumps(summary, indent=2))
