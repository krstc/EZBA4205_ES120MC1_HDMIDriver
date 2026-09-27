"""Exhaustively compare the short drive rule with the supplied EPDiy DU LUT."""
import ast
import hashlib
import re
from pathlib import Path

source = Path(__file__).resolve().parents[2] / 'datasheet/src/ES120MC1-EpdiyV7/lib/epdiy2/src/waveforms/epdiy_ED047TC1.h'
match = re.search(r'epd_wp_epdiy_ED047TC1_1_0_data[^=]*=\s*(\{.*?\});', source.read_text(), re.S)
table = ast.literal_eval(match[1].replace('{', '[').replace('}', ']'))
assert len(table) == 5
codes = []
for phase in range(5):
    for target in range(16):
        for old in range(16):
            actual = (table[phase][target][old // 4] >> (6 - 2 * (old % 4))) & 3
            expected = 1 if target == 0 and old != 0 else 2 if target == 15 and old != 15 else 0
            assert actual == expected, (phase, target, old, actual, expected)
            codes.append(actual)
print('PASS all 1280 EPDiy DU entries match the five-phase endpoint-drive rule; neutral tail is separate')
print('DU table SHA256:', hashlib.sha256(bytes(codes)).hexdigest())
