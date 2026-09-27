# HDMI input diagnostic, 2026-09-18

Status: fixed and verified through live JTAG capture. NAND was not written
during this diagnostic session.

## Root cause

The ADV7611 was locked to the 2650x1600 25 Hz source, but the FPGA XDC mapped
several Y data bits as DE/HS/VS. Consequently the design saw a valid TMDS
clock while its geometry and frame-rate qualifiers never received real sync
signals, leaving the UI at `TMDS 115M WAIT`.

The expansion schematic DATA3 labels do not describe the wiring on this
assembled board. Timing closure with those labels therefore was not proof of
a correct pinout.

## Measured parallel bus mapping

The ADV7611 was temporarily put in free-run/manual-default-color mode through
JTAG. Channel A (Y) was driven with one-hot values 0x01 through 0x80 while an
ILA sampled all twelve candidate pins. Each one-hot bit identified exactly
one physical wire. The original registers were restored after the test.

| FPGA port | Package pin | ADV7611 signal |
| --- | --- | --- |
| `pix_clk` | P19 | LLC / 115.63 MHz pixel clock |
| `de_i` | U20 | DE |
| `hs_i` | U19 | HS |
| `vs_i` | V20 | VS |
| `gray_i[7]` | T20 | Y7 / P15 |
| `gray_i[6]` | R18 | Y6 / P14 |
| `gray_i[5]` | N20 | Y5 / P13 |
| `gray_i[4]` | P18 | Y4 / P12 |
| `gray_i[3]` | N17 | Y3 / P11 |
| `gray_i[2]` | P20 | Y2 / P10 |
| `gray_i[1]` | R19 | Y1 / P9 |
| `gray_i[0]` | T19 | Y0 / P8 |

The live sync behavior independently matched the mapping: U20 had the active
video duty cycle and line boundaries, U19 had the narrow line-sync pulse, and
V20 was the remaining frame-sync line.

## Source timing and constraints

- Active video: 2650x1600; the capture path crops 45 pixels on each side to
  the 2560-pixel panel width.
- Total timing: 2810x1646.
- Pixel clock: 115.63 MHz, constrained as 8.648275 ns.
- Full-frame rate: 24.9997 Hz from the EDID timing.

## Verification

The corrected normal build (without `HDMI_PINOUT_ILA`) is in
`build/hdmi_pinmap_fix_20260918/`.

- EDID, HDMI input/crop, HDMI handoff, and panel transport simulations pass.
- Routed timing passes: WNS +1.182 ns, WHS +0.007 ns; all user timing
  constraints are met.
- Live ADV7611 status is 0x23 and TMDS is approximately 115 MHz.
- Live FPGA qualifiers report `hdmi_valid_sync=1` and `hdmi_rate_valid=1`.
- Measured VS period is 2,000,008 cycles at 50 MHz, or 24.9999 Hz.
- Status manager state was 8 (`DISPLAY_WAIT`) during the capture, proving the
  design left the diagnostic wait state and was displaying a captured HDMI
  frame.

The JTAG-programmed image is temporary. NAND still contains the preceding
image until the corrected boot image is explicitly flashed. The prepared,
unflashed candidate is
`build/hdmi_pinmap_fix_20260918/BOOT_HDMI_PINMAP_FIX_20260918.bin`
(6,421,072 bytes, MD5 `0DE8FD1C4B9CA4CE3D2F13C577E74E93`, SHA-256
`EBC03134E34E112CCA34290661F9DBC53B2435F25EDC3037D27F008FA9616A17`).

## Rejected schematic-based experiment

An earlier trial assigned VS/HS/DE/PCLK from the expansion schematic. It met
static timing but T20 did not behave as a clock in live capture. That trial is
under `build/rejected_hdmi_pinout_20260918/` and its boot image is named
`REJECTED_DO_NOT_FLASH.bin`; it must not be used.

Reference: ADV7611 Reference Manual UG-180, output-format, output-tristate,
free-run/default-color, and HDMI-status register descriptions.
