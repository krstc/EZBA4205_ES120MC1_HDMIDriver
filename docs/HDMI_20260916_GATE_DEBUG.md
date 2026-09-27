# 2026-09-16 HDMI 停留 NO SIGNAL 的诊断与修复

## 结论和验证边界

发现并在生产顶层仿真中复现了一个确定的逻辑错误：EDID 所声明的
115.63 MHz 输入被顶层的 115 MHz 上限拒绝，`hdmi_capture_valid` 始终不能置位。
修复后同一测试可以进入 HDMI 采集，并通过拔插、恢复、错误模式拒绝测试。
此处的“修复通过”指代码和仿真；尚未取得修复后板上 HDMI 显示成功的证据。

本轮两次尝试读取运行中的 ILA（含 1 MHz JTAG 重试），均返回
`No devices detected on target .../XILINX000053A`。没有复位板卡、修改 NAND
或获得板内寄存器读数。不能把 Windows 读数说成 ADV7611 的实测寄存器值。

## Windows 的实测数据

`diagnostics/read_windows_signal.ps1` 使用只读的
[QueryDisplayConfig](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-querydisplayconfig)
查询当前活动输出，而非只读取 EDID 的首选模式。

| 项目 | 本轮 Windows 实际输出 |
| --- | --- |
| 显示器 | ES120MC1-25Hz / EPD0133 |
| 桌面尺寸 | 2650 x 1600 |
| 活动信号尺寸 | 2650 x 1600 |
| 总时序尺寸 | 2810 x 1646 |
| 像素时钟 | 115.63 MHz |
| 帧率 | 24.9996756939069 Hz |

原始记录：`build/releases/20260916_hdmi_gate_fix/windows_active_signal.json`。
WMI EDID 记录：同目录 `windows_edid_before.json`。

注意：Windows 可见 EDID 的产品号为 0133，且带一块 CTA 扩展；源码基础块
产品号为 0132，扩展数为 0。二者首选 DTD 一致，但并非逐字节相同。
扩展坞、缓存或实际运行版本的区别尚未通过板内回读确认，本轮不改 EDID。

## 直接故障原因

上一版 `eink_controller_es120mc1.v` 的条件是：

```verilog
hdmi_tmds_q7 >= 16'd13824 && hdmi_tmds_q7 <= 16'd14720
```

这是 108 至 115 MHz。实际 EDID 的像素时钟换算为 Q7：

```text
115.63 * 128 = 14800.64，约为 14801
14801 > 14720
```

因此，即便 I2C 配置、锁定和输入视频全部正确，连续有效计时器也无法累加。
这是频率判定与 EDID 不一致的问题，延长采集超时或增加消抖不能解决。

新门限为 113*128 至 118*128，即 14464 至 15104，包含 115.63 MHz。
最终有效条件同时检查：EDID 已验证、ADV7611 锁定、频率读取有效、
频率在窗内、原始 DE 尺寸符合 2650 x 1600、独立 VS 测得 24 至 26 Hz。
已有的 100 ms 连续有效、1 s 持续丢失消抖保留。

`hdmi_input_es120mc1.v` 仍裁去左右各 45 像素，写入 2560 x 1600 面板缓冲。
EDID/I2C 初始化、面板扫描时序、LUT、开机图案及清屏状态机没有修改。

## 回归验证

1. `es120_hdmi_handoff_tb` 直接实例化生产顶层，从实际配置表解析 EDID 时钟。
   修复前在 q7=14801 处失败，日志为 `handoff_before_fix.log`；修复后通过。
   同时检查 HDMI 源切换、短暂读取故障、持续断开、错误尺寸、错误/停止 VS、
   268.5 MHz 输入拒绝和重新接入。此测试模拟接收器状态及 DDR/面板完成接口，
   不代表物理 HDMI 或真实 DDR 控制器实测。
2. `es120_capture_tb` 以 115.63 MHz 像素域、50 MHz 系统域输入两帧完整
   2650 x 1600 数据，经过生产裁剪、异步 FIFO、灰度写入和黑白 DU 转换。
   加入 DMA 停顿，逐项核对 8,192,000 个裁剪后像素及驱动码，全部通过。
   DMA 响应和旧帧输入由测试模型提供；不覆盖物理 DDR 仲裁最坏延迟。
3. `es120_hdmi_input_tb` 同时覆盖 2560 原生模式和实际 2650 兼容模式，
   检查 45+2560+45 边界、像素次序、错误尺寸拒绝及恢复。
4. `es120_hdmi_timing_tb`、`es120_edid_tb`、`es120_boot_tb` 均通过。

## 构建结果和镜像

Vivado 2026.1 完成综合、布局布线和位流生成。现有约束下 WNS=+1.373 ns、
WHS=+0.052 ns；总线偏斜报告全部通过，最小余量 +4.923 ns；DRC 无错误。
报告仍包含既有 XDC/IP 告警和部分输入延时约束提示，并非零告警工程。
这些检查不能代替 ADV7611 并行口和实际 DDR 的上板测量。

NAND 待测镜像：`build/releases/20260916_hdmi_gate_fix/BOOT.bin`。

- 大小：6,421,072 字节。
- MD5：`AD2CC002F938E44AFCA6D84BDFBFF1DB`。
- SHA256：`28727EB9244764D8D37D96CAAD5060EC0C38E1894AC382D13E5442B4C30F0217`。
- 沿用已验证的 DDR15 FSBL 和 frame-buffer ELF，打包成功。
- `source` 保存本轮 RTL、约束、测试与构建脚本快照。
- 旧版 `20260915_hdmi_stable_capture` 发布目录保持原样。
- 本轮没有烧录 NAND，也没有完成 HDMI 实机画面验证。

## 新 ILA probe3

使用此版本随附的 `fpga.ltx`，不能使用旧版探针文件。
probe0、1、2、4 的物理宽度与含义保留；probe3 改为采集路径诊断。

| probe3 位 | 含义 |
| --- | --- |
| 16:13 | 请求采集次数，模 16 |
| 12:9 | 完成采集次数，模 16 |
| 8:5 | 完成显示次数，模 16，含初始化 |
| 4 | 同步后的并行视频尺寸有效 |
| 3 | 全部放行条件成立，消抖前 |
| 2 | 消抖后的 HDMI 有效 |
| 1 | 当前选用 HDMI 像素源 |
| 0 | 数据通路运行使能 |

probe1 是 TMDS 频率整数部分；小数部分未送入该探针。
probe2 的位 9 是 EDID 验证、位 8 是频率读取有效，低 8 位是 HDMI 0x04。
probe4 的位 8:1 是测得 VS 周期的 23:16 位，位 0 是帧率有效。
在 50 MHz 系统域下，25 Hz 的完整 VS 周期应约为 2,000,000 个周期。

示例：

```powershell
& D:/FPGA_IDE/2026.1/Vivado/bin/vivado.bat -mode batch `
  -source ./build/read_current_hdmi_ila.tcl -notrace `
  -tclargs ./build/releases/20260916_hdmi_gate_fix ./build/hdmi_live.csv
```

此脚本只读取运行设计，不下载位流。如果计数“请求增加、完成不增加”，
应继续检查采集/DMA；若尺寸或帧率无效，应先检查 ADV7611 并行输出。
不能再次通过取消尺寸检查来掩盖问题。
