# ES120MC1 text local-GC16 candidate baseline

Date: 2026-09-25

This candidate is based on `2026-09-24_text_no_auto_clean_nand_verified`.

## Behavior

- Smooth mode remains the existing 16x16 blue-noise dither plus DU path.
- Text mode applies DU only to source pixels that changed.
- A changed text pixel is refined with GC16 locally after its DU transition.
- A stable text image waits 2 seconds, then requests exactly one full-frame GC16 refinement.
- The idle full-frame refinement is not repeated while the source remains unchanged.
- A new source frame rearms the timer and allows one later full-frame refinement.
- Smooth-mode automatic cleanup remains disabled.

## Verification

The focused tests and the 2560x1600 full-frame DDR datapath test passed. The full-frame test used 25 Hz HDMI timing, overlapping capture/display, three panel fields, and all pin codes.

Implementation result for `xc7z010clg400-1`:

- WNS: `+0.080 ns`
- TNS: `0.000 ns`
- WHS: `+0.050 ns`
- THS: `0.000 ns`
- DRC errors: `0`

## GC16 speed reference

The current GC16 waveform has 30 active scans plus 2 neutral scans. At the current panel clock, a full-panel pass is about 426.6 ms, or about 2.34 full passes per second, versus the 25 Hz smooth DU budget. A full-panel GC16 pass is therefore about 10.7x slower. Local GC16 work is proportional to changed pixels; the 2-second idle pass is one-shot.

## Release hashes

- `release/fpga.bit` MD5: `FBAB25C75A64EB02087F0A74020D2CD8`
- `release/fpga.bit` SHA256: `FA58A5F267F4C2884052111925A4623E52AC17C4BC10BBD19B8132ED54DB19A7`
- `release/BOOT.bin` MD5: `0C263554B899C6E77EE4C0B34E5FCE69`
- `release/BOOT.bin` SHA256: `659FFEAFD445BE4D17C92D4F4EA19F58B9359DC13A7FBBF7130664A1DCFDDD34`

The release directory contains the bitstream, LTX, BOOT.bin, reports, and the previously verified FSBL/application payloads. No device was connected or programmed during this build.
