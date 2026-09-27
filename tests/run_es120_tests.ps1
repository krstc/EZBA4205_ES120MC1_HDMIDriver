param([string]$Top = 'es120_transport_tb')
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$src = Join-Path $repo 'c/p/Eink_controller_V1.0.srcs/sources_1/new'
$out = Join-Path $repo "build/tests/$Top"
New-Item -ItemType Directory -Force -Path $out | Out-Null
$bin = 'D:/FPGA_IDE/2026.1/Vivado/bin'
Push-Location $out
try {
    $files = @('data_mgr.v','frame_ctrl_es120mc1.v','display_mgr_es120mc1.v',
        'status_manager_es120mc1.v','status_source_es120mc1.v','fdma_w_mono_es120mc1.v',
        'xpm_fifo_wdata_buf.v','xpm_fifo_rdata_buf.v','sync_h2lck.v',
        'gc16_lut_es120mc1.v','fdma_w_gc16_es120mc1.v','fdma_r_gc16_es120mc1.v',
        'du5_lut_es120mc1.v','pixel_step_es120mc1.v','pixel_packet_es120mc1.v','stream_manager_es120mc1.v','fdma_r_packet_es120mc1.v',
        'fdma_page_guard_es120mc1.v',
        'fdma_clear.v',
        'fdma_w_gray.v','xpm_fifo_wgray_buf.v','xpm_cdc_async_rst_n.v','level2pulse.v',
        'config_reg_es120mc1.v','hdmi_timing_qualifier.v','hdmi_frame_guard_es120mc1.v',
        'hdmi_input_es120mc1.v',
        'adv7611_iic_manager.v','i2c_top.v') |
        ForEach-Object { Join-Path $src $_ }
    if ($Top -eq 'es120_hdmi_handoff_tb') {
        $files += @('eink_controller_es120mc1.v','clock_pll_es120mc1.v',
            'delay_cnt.v','tps65185_ctrl.v') | ForEach-Object { Join-Path $src $_ }
    }
    if ($Top -in @('es120_recovery_capture_tb','es120_gc16_capture_tb')) {
        $files += Join-Path $PSScriptRoot 'es120_capture_tb.sv'
    }
    if ($Top -in @('es120_gc16_fullscreen_tb','es120_gc16_normal_tb',
                  'es120_hybrid_fast_transport_tb','es120_hybrid_refine_transport_tb')) {
        $files += Join-Path $PSScriptRoot 'es120_gc16_transport_tb.sv'
    }
    if ($Top -in @('es120_gc16_waveform_tb','es120_hybrid_waveform_tb')) {
        $files += Join-Path $PSScriptRoot 'es120_waveform_tb.sv'
    }
    if ($Top -eq 'es120_hybrid_quantizer_tb') {
        $files += Join-Path $PSScriptRoot 'es120_gc16_quantizer_tb.sv'
    }
    if ($Top -eq 'es120_hybrid_datapath_tb') {
        $files += @('frame_processor.v','addr_sw.v','fdma_r_gray.v','xpm_fifo_rgray_buf.v') |
            ForEach-Object { Join-Path $src $_ }
    }
    if ($Top -like 'es120_stream_*path_tb') {
        $files += Join-Path $src 'frame_stream_es120mc1.v'
        $files += Join-Path $PSScriptRoot 'stream_ddr_model.sv'
    }
    & "$bin/xvlog.bat" -sv @files (Join-Path $PSScriptRoot "$Top.sv") "$bin/../data/verilog/src/glbl.v"
    if ($LASTEXITCODE -ne 0) { throw 'xvlog failed' }
    & "$bin/xelab.bat" $Top glbl -L xpm -L unisims_ver -s $Top -debug typical
    if ($LASTEXITCODE -ne 0) { throw 'xelab failed' }
    & "$bin/xsim.bat" $Top -runall -log simulation.log
    if ($LASTEXITCODE -ne 0) { throw 'xsim failed' }
    $log = Get-Content simulation.log -Raw
    if ($log -notmatch 'PASS ' -or $log -match 'Fatal:|Error:') { throw 'Test did not pass' }
} finally { Pop-Location }
