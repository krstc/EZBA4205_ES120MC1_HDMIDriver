"""Offline checks for the gamma-aware binary-DU5 candidate."""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RTL = ROOT / 'c/p/Eink_controller_V1.0.srcs/sources_1/new'
BEFORE = ROOT / 'build/hdmi_spatial_du5_20260921/source_before/rtl'

hdmi = (RTL / 'hdmi_input_es120mc1.v').read_text()
top = (RTL / 'eink_controller_es120mc1.v').read_text()

assert 'parameter GAMMA_AWARE_DITHER = 1' in hdmi
assert 'function [7:0] gamma_aware_level' in hdmi
assert 'shift/add lift restores midtones' in hdmi
assert 'expanded} >> 3' in hdmi and 'expanded} >> 4' in hdmi
assert 'dither_level_s2 <= (VIDEO_LEVELS_ENABLE && !NATIVE_GC16 && GAMMA_AWARE_DITHER)' in hdmi
assert '.GAMMA_AWARE_DITHER(1)' in top

# The contrast candidate must not silently alter the already verified panel
# timing, receiver setup, or 25 Hz geometry.
for name in ('clock_pll_es120mc1.v', 'frame_ctrl_es120mc1.v',
             'config_reg_es120mc1.v', 'adv7611_iic_manager.v'):
    assert (RTL / name).read_bytes() == (BEFORE / name).read_bytes(), name

assert '.DITHER_ENABLE(1), .NATIVE_GC16(0), .VIDEO_LEVELS_ENABLE(1)' in top
assert '.USE_NATIVE_GC16(0)' in top
assert re.search(r'display_mgr_es120mc1 #\([\s\S]*?\.NATIVE_GC16\(0\)', top)

print('PASS gamma-aware DU5 release: explicit square-law dither, unchanged 2560x1600/25Hz HDMI and DU5 path')
