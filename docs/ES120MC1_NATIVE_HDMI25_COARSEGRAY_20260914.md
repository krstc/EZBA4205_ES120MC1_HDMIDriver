# ES120MC1 Native HDMI 25 Hz Candidate

Build date: 2026-09-14

## Purpose

This candidate addresses two symptoms from the previous half-gray build:

- the lower panel area showed a dense speckle field because the 50% startup
  pattern was a 2x2 per-pixel dither;
- Windows could enumerate the EDID at 2560x1600@25 Hz, but the FPGA still
  reported no signal because the receive path expected 2650 active pixels and
  a TMDS window centered on the old 2650-pixel mode.

## HDMI configuration

The EDID and receiver now use the native panel width. There is no horizontal
crop in `hdmi_input_es120mc1.v`.

| Parameter | Value |
|---|---:|
| Active width | 2560 pixels |
| Active height | 1600 lines |
| Horizontal front/sync/back | 48 / 32 / 80 |
| Horizontal total | 2720 |
| Vertical front/sync/back | 3 / 6 / 37 |
| Vertical total | 1646 |
| Pixel clock | 111.93 MHz |
| Frame rate | 25.000447 Hz |
| EDID DTD bytes 54..56 | `B9 2B 00` |
| EDID checksum byte 127 | `5D` |

HDMI capture is selected only after EDID readback verification, ADV7611 TMDS
lock, successful frequency status reads, exact 2560x1600 raw DE geometry, and
the independent 24..26 Hz frame-rate check. The TMDS acceptance window is
13824..14720 in the q7 representation, covering the 111.93 MHz source. The
previous 2650-pixel crop and 113..118 MHz-only gate are removed.

## Startup half-gray

The startup dark stripe is still 50% black on average, but uses an 8-line
coarse block pattern (`y[3] == 0`) instead of a fine 2x2 spatial dither. This
avoids the dense dot texture while preserving the existing binary DU path.
The NO SIGNAL text and HDMI image conversion remain binary and are unchanged.

## Verification

All ten ES120 Xsim tests passed, including EDID, exact native input geometry,
25 Hz timing qualification, startup state transitions, DMA packing, and
HDMI reconnect behavior.

Vivado 2026.1 implementation completed successfully:

- DRC errors: 0
- final setup WNS: +0.951 ns
- final hold WHS: +0.052 ns
- panel setup and hold reports: positive slack

## NAND candidate

`build/releases/20260914_native2560_hdmi25_coarsegray/BOOT.bin`

- size: 6,421,072 bytes
- MD5: `525B36E183DE477B57633E8CA78F0156`
- SHA256: `05C4E39D9C6B9514949ADA6C4B00C7137E2EDFC007F54E8594D8ED8B2631A326`

This task only generated the candidate; it did not program NAND.
