# HDMI 接收器轮询覆盖频率的修复（2026-09-16）

## 已确认的代码问题

`adv7611_iic_manager.v` 的 `DETECT_READ` 状态读取七个寄存器：

| detect_index | I2C 地址（8 位写地址） | 寄存器 | 用途 |
| --- | --- | --- | --- |
| 0 | 0x68 | 0x04 | TMDS 锁定状态 |
| 1 | 0x68 | 0x51 | TMDS 频率高字节 |
| 2 | 0x68 | 0x52 | TMDS 频率低字节 |
| 3 | 0x98 | 0x6A | 附加诊断 |
| 4 | 0x68 | 0x07 | 附加诊断 |
| 5 | 0x68 | 0x1B | 附加诊断 |
| 6 | 0x68 | 0xE0 | 附加诊断 |

旧代码对索引 0 和 1 分别处理，其余索引全部进入 `else`，把读值当成
频率低字节，并重新赋值 `hdmi_frequency_valid`。这使索引 3 到 6 的诊断值
和 NACK 都能覆盖索引 2 已完成的频率采样。

修复仅将该分支限制为 `else if (detect_index == 2)`。诊断读取继续更新
`verify_read_address / verify_read_data / verify_read_ack_error`，但不能修改
已经完成的频率采样或其有效标志。真正的锁定丢失及频率读取错误仍会使视频无效。

没有取消顶层的 EDID 验证、频率有效、锁定、频率窗口、完整帧尺寸及帧率检查。
顶层文件与上一版 `20260916_hdmi_gate_fix` 的 SHA256 相同。
面板时序、LUT、EDID、开机图案和清屏流程均未更改。

## 复现与回归

旧接收器单元测试只检查频率刚读出时的瞬时值，没有检查整个轮询结束后的值。
现已扩展为完整轮询、连续多轮、诊断 NACK、频率读取 NACK、锁定丢失及恢复。

旧代码的失败记录：

```text
poll corrupted frequency/status:
expected q7=39d1 valid=1, got q7=3900 valid=1
```

联合测试 `es120_hdmi_handoff_tb` 现在实例化真实接收器状态机和真实顶层门控。
测试在 I2C 事务边界提供应答，不再强制赋值接收器的锁定、频率、频率有效和
EDID 验证输出。附加诊断寄存器持续 NACK 时，旧版反复打断有效计时：等待超过
100000 个缩放后的系统周期后，采集次数仍为 0；修正版完成接管、拔出与重连。

测试覆盖：

- 完整 EDID 校验后再释放 HPD；损坏数据、EDID enable NACK、未激活状态拒绝。
- 115.63 MHz 和 268.5 MHz 频率样本完整性；诊断 NACK 与频率 NACK 分别处理。
- 真实轮询状态机驱动顶层，100 ms/1 s 消抖计数按比例缩短进行测试。
- HDMI 采集切换，错误尺寸/帧率拒绝，短暂状态故障、持续拔出和重新接入。
- EDID 内容与开机初始化、竖条保持、三轮清屏、静态 NO SIGNAL 回归。

I2C 引脚电气、ADV7611 实际寄存器值、并行视频尺寸和 DDR/面板完成接口仍属于
模型或独立测试的边界。模拟诊断 NACK 能证明故障机制，但不能证明现场必然发生
同样的 NACK；不能用仿真通过替代 HDMI 画面上板验收。

日志保存在 `build/releases/20260916_hdmi_poll_fix`：
`receiver_poll_before_fix.log`、`receiver_poll_after_fix.log`、
`handoff_poll_before_fix.log`、`handoff_poll_after_fix.log`。

## 本轮现场观测与限制

Windows QueryDisplayConfig 读到的活动信号为 2650x1600、总计 2810x1646、
115.63 MHz、24.9996756939069 Hz。2650 为现有兼容 EDID，FPGA 裁去左右各 45
像素后写入 2560x1600 面板缓冲。本轮没有修改该已使用的模式。

读取运行中 ILA 的三次尝试（包括 1 MHz JTAG）均返回 `No devices detected`。
因此本轮尚无 FPGA 内部频率/锁定/采集计数的现场读数。请保持 HDMI 接入，
保持 NAND 启动并连接 JTAG 后读取故障现场，无须先重置或下载设计。
Windows 端的活动信号数据并不等同于接收器输出的实测数据。

Vivado 完整构建和 Bootgen 已完成，生成 6,421,072 字节的 `BOOT.bin`。
约束内时序为 WNS +1.144 ns、WHS +0.050 ns；40 项总线偏斜检查的最小裕量
为 +4.913 ns。面板数据输出建立/保持最小裕量分别为 +21.057 / +26.297 ns。
DRC 无错误，但工程仍有 IP/XDC 和方法学警告；方法学报告包含
`clk_50m_mmcm` 与 `clk_fpga_0` 的 TIMING-6/7 时钟关系警告。因此这里的
时序通过是对当前约束的检查结果，不是板上采样正确或全工程无警告的证明。

本轮尚未写入 NAND，也没有 HDMI 画面的硬件验收。镜像及详细构建状态见
发布目录 `README.md`；前一版镜像保留不变。
