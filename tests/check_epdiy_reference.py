"""Check the binary FPGA waveform against the actual local C initializer."""
import ast
from pathlib import Path
import re

root = Path(__file__).resolve().parents[2]
reference = root / "datasheet/src/ES120MC1-EpdiyV7/lib/epdiy2/src"
source = (reference / "waveforms/epdiy_ED047TC1.h").read_text()
match = re.search(r"epd_wp_epdiy_ED047TC1_1_0_data\[5\]\[16\]\[4\]\s*=\s*(\{.*?\});", source)
assert match, "MODE_DU initializer missing"
phases = ast.literal_eval(match[1].replace("{", "[").replace("}", "]"))
assert len(phases) == 5
for index, phase in enumerate(phases):
    assert len(phase) == 16 and all(len(row) == 4 for row in phase)
    for target in (0, 15):
        for previous in (0, 15):
            c_drive = (phase[target][previous // 4] >> (6 - 2 * (previous % 4))) & 3
            rtl_drive = 0 if target == previous else (2 if target == 15 else 1)
            assert c_drive == rtl_drive, (index, previous, target, c_drive)
display = (reference / "displays.c").read_text()
es120 = re.search(r"const EpdDisplay_t ES120 = \{(.*?)\};", display, re.S)[1]
assert ".width = 2560" in es120 and ".height = 1600" in es120
assert ".bus_width = 16" in es120 and "&epdiy_ED047TC1" in es120
hz = 50_000_000 * 13 / 14.75
assert 2560*1600 <= 4*1024*1024
assert 2560*1600//4 <= 1024*1024
print("PASS reference: all 20 binary MODE_DU LUT entries match the C waveform; framebuffer extents fit")
print(f"SDCK={hz:.6f} Hz, line={362/hz*1e6:.6f} us, full scan={hz/(362*1623):.6f} Hz")
rtl = root / "eink/c/p/Eink_controller_V1.0.srcs/sources_1/new"
top = (rtl / "eink_controller_es120mc1.v").read_text(encoding="utf-8")
assert re.search(r"HDMI_DU_PHASES\s*=\s*5\s*[,;]", top), "Incomplete DU phase count"
assert ".LOCAL_RECOVERY_ENABLE(1)" in top and ".BOOT_WHITE_CLEAN(1)" in top
print(f"DU5 waveform ceiling={hz/(362*1623*5):.6f} Hz; HDMI capture/join can reduce actual updates")
print(f"Local W10/N2 recovery duration={12*362*1623/hz*1000:.6f} ms")
print("Reference LCD renderer ignores phase_times/time in epd_push_pixels_lcd; these are not millisecond delays.")
