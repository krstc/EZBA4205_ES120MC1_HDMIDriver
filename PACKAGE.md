# ES120MC1 Baseline Package

This directory is the verified `2026-09-25_text_local_gc16_idle` baseline for the ES120MC1 2560x1600 controller.

Contents:

- `rtl/`: baseline RTL sources, including the ES120MC1 datapath and waveform logic.
- `constraints/`: panel and board timing constraints.
- `tests/`: focused simulation and regression tests.
- `release/`: bitstream, `BOOT.bin`, FSBL/application payloads, timing reports, and hashes from the verified build.
- `tools/`: Vivado build and JTAG programming scripts.
- `docs/`: HDMI, EDID, panel timing, and waveform notes.

The `release/BOOT.bin` image was programmed to NAND with `nand-x8`, offset `0`, and verified successfully on 2026-09-27.
