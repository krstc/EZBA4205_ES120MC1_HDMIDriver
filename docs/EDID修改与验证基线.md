# EDID 修改与验证基线

> 2026-09-11 核对说明：本文保留 8 月 18 日历史测试记录。成功模式是
> **2650 x 1600 @ 25 Hz**，不是面板原生 2560 宽。文中旧 DTD 的水平同步宽度、
> 固定校验字节和“芯片不会自动修正校验和”的表述不可直接复制到新版本。
> 当前兼容性候选及逐项更正见 [20260911 核对记录](EDID_20260911_BASELINE_COMPARISON.md)。

## 1. 基线结论

本项目第一阶段已经验证完成：FPGA 通过 I2C 配置 ADV7611 的内部 EDID RAM，ADV7611 再通过 HDMI DDC 向电脑提供 EDID。电脑能够重新枚举显示器，并正确识别自定义时序。

本次最终验证的配置为：

| 项目 | 值 |
| --- | --- |
| 显示器名称 | ES120MC1 |
| 分辨率 | 2650 x 1600 |
| 目标刷新率 | 25 Hz |
| 实际计算刷新率 | 24.9997 Hz |
| 像素时钟 | 115.63 MHz |
| 水平消隐 | 160 pixels |
| 垂直消隐 | 46 lines |
| EDID 校验和 | 0（128 字节总和模 256 为 0） |
| 验证方式 | JTAG 下载 bitstream，Windows 重新枚举显示器 |
| NAND | 未改写 |

Windows 最终枚举到新的显示器实例 `DISPLAY\\EPD0129\\...`，从注册表回读的原始 EDID DTD 为：

```text
2B 2D 5A A0 A0 40 2E 60 30 80 36 00 03 A2 10 00 00 1E
```

回读结果为 `2650 x 1600`、EDID 校验和 `0`。这说明本次修改已经通过了“FPGA 写入 -> ADV7611 保存 -> HDMI DDC 输出 -> Windows 读取”的完整链路。

## 2. 正确的数据链路

本工程不是让电脑直接读取 FPGA 中的 Verilog 数组，而是通过以下链路提供 EDID：

```text
FPGA I2C master
    |
    | 通过 ADV7611 配置 I2C 通道写入 EDID RAM
    v
ADV7611 内部 EDID RAM
    |
    | HDMI DDC / I2C 从设备接口
    v
电脑显卡读取 EDID
```

因此必须同时满足以下条件：

1. ADV7611 的 I2C 配置通路正常，写事务得到 ACK。
2. EDID RAM 在对外发布前已经写完整，特别是字节 `0x7F` 校验和。
3. ADV7611 的内部 EDID 被使能。
4. HPD/HPA 必须产生一次有效的重新枚举动作，使显卡丢弃旧缓存并重新读取 EDID。

仅修改 EDID 字节而不触发 HPD，Windows 可能继续显示旧模式；这正是之前反复看到 1080p 的主要原因之一。

## 3. 源码位置

EDID 主表：

```text
controller/Eink_controller_V1.0/
  Eink_controller_V1.0.srcs/sources_1/new/config_reg_es120mc1.v
```

ADV7611 配置状态机和 HPD/EDID 发布流程：

```text
controller/Eink_controller_V1.0/
  Eink_controller_V1.0.srcs/sources_1/new/adv7611_iic_manager.v
```

当前测试构建脚本：

```text
build/build_es120mc1_jtag_diagnostic.tcl
```

当前 JTAG 下载脚本：

```text
build/inspect_edid_ila_jtag.tcl
```

当前验证 bitstream：

```text
build/es120mc1_jtag_diagnostic/
  EBAZ4205_ES120MC1_EDID_DIAGNOSTIC.bit
```

## 4. EDID 基本块修改方法

### 4.1 保持固定字段

基础 EDID 的字节编号从 `0x00` 到 `0x7F`。以下字段保持工程当前值，除非有明确的显示器资料要求：

```text
0x00..0x07  EDID header: 00 FF FF FF FF FF FF 00
0x08..0x09  厂商标识
0x0A..0x0B  产品代码
0x12..0x13  EDID 版本
0x14..0x35  能力和标准时序描述
0x48..0x53  其他标准时序/保留字段
```

本次将产品代码字节设为：

```text
byte 0x0A = 0x28
byte 0x0B = 0x01
```

修改产品代码的目的，是让 Windows 为新 EDID 创建新的显示器实例，减少旧模式缓存影响。产品代码不是刷新率配置本身，不能替代 EDID 校验和或 HPD 重新枚举。

### 4.2 修改详细时序 DTD

基础 EDID 第一个 Detailed Timing Descriptor 位于字节 `0x36..0x47`，也就是十进制字节 `54..71`。

DTD 的字段关系如下：

```text
byte 54..55: pixel clock，单位 10 kHz，小端格式
byte 56:     horizontal active 低 8 位
byte 57:     horizontal blanking 低 8 位
byte 58[7:4]: horizontal active 高 4 位
byte 58[3:0]: horizontal blanking 高 4 位
byte 59:     vertical active 低 8 位
byte 60:     vertical blanking 低 8 位
byte 61[7:4]: vertical active 高 4 位
byte 61[3:0]: vertical blanking 高 4 位
byte 62..64: 同步偏移、同步宽度等时序字段
byte 65..71: 垂直同步和图像尺寸字段
```

刷新率计算公式：

```text
pixel_clock_hz = pixel_clock_10khz * 10000
htotal = hactive + hblank
vtotal = vactive + vblank
refresh_hz = pixel_clock_hz / (htotal * vtotal)
```

本次使用的参数：

```text
hactive       = 2650
hblank        = 160
htotal        = 2810

vactive       = 1600
vblank        = 46
vtotal        = 1646

pixel_clock   = 115.63 MHz
refresh       = 115.63e6 / (2810 * 1646)
              = 24.9997 Hz
```

对应 DTD 字节为：

```text
byte 54..71:
2B 2D 5A A0 A0 40 2E 60 30 80 36 00 03 A2 10 00 00 1E
```

### 4.3 修改范围描述符

EDID 的 Monitor Range Limits Descriptor 位于本工程基础块的字节 `0x5D..0x66` 附近。对于本次 25 Hz 测试，源码中使用了与目标时序匹配的范围：

```text
minimum vertical rate    = 24 Hz
maximum vertical rate    = 26 Hz
minimum horizontal rate  = 40 kHz
maximum horizontal rate  = 42 kHz
maximum pixel clock      = 120 MHz
```

对应源码字段为：

```text
byte 95 = 0x18
byte 96 = 0x1A
byte 97 = 0x28
byte 98 = 0x2A
byte 99 = 0x0C
```

范围描述符不能替代 DTD。显卡通常优先使用 DTD 中的具体模式，但范围必须覆盖 DTD 的实际刷新率和像素时钟。

### 4.4 重新计算校验和

EDID 基础块的校验规则：

```text
sum(byte[0..127]) mod 256 == 0
```

正确流程是：

1. 先写完字节 `0x00..0x7E`。
2. 将 `byte[0x7F]` 暂时置为 `0`。
3. 计算前 127 字节的和。
4. `byte[0x7F] = (256 - (sum(byte[0..126]) mod 256)) mod 256`。
5. 再验证全部 128 字节总和模 256 为 `0`。

本次 `2650x1600@25Hz` 的校验和为：

```text
byte 0x7F = 0x50
sum(byte[0..127]) mod 256 = 0
```

此前出现的 `0x84` 是错误校验和，会导致 EDID 基础块非法，显卡可能回退到 1920x1080@60Hz。

## 5. ADV7611 写入和发布顺序

### 5.1 先关闭对外发布

`adv7611_iic_manager.v` 在正式配置表之前执行预配置序列，使 ADV7611 暂时不发布旧 EDID，并准备 HPD/HPA 控制。当前预配置序列包含：

```text
98 FF 80
98 F4 80
98 F5 7C
98 F8 4C
98 F9 64
98 FA 6C
98 FB 68
98 FD 44
68 6C A3
98 20 70
64 74 00
```

其中每行分别表示：

```text
I2C slave address, register address, register value
```

### 5.2 写入 EDID RAM

`config_reg_es120mc1.v` 中 `REG_INDEX=50..177` 对应 EDID 字节 `0x00..0x7F`：

```text
EDID byte offset = REG_INDEX - 50
I2C device       = 0x6C
I2C register     = EDID byte offset
I2C data         = edid_byte(EDID byte offset)
```

因此必须写入全部 128 个字节，不能只写 DTD 或只写前 127 个字节。特别是 `byte 0x7F` 必须明确写入 `0x50`，ADV7611 不会替 FPGA 自动修正校验和。

源码中应保持以下位宽写法：

```verilog
REG_DATA = {8'd3, 8'h6c, REG_INDEX[7:0] - 8'd50,
            edid_byte(REG_INDEX[7:0] - 8'd50), 8'h00};
```

这里的 `REG_DATA` 必须保持 40 位、事务长度必须为 3。不要直接使用 9 位 `REG_INDEX` 拼接，否则可能导致事务位宽膨胀，破坏 ADV7611 的 EDID 写入。

### 5.3 使能 EDID 并触发重新枚举

当前验证成功的尾部顺序必须保持不变：

```text
index 178: 64 74 01   enable internal EDID
index 179: 98 20 F0   release/assert HPD high for re-enumeration
index 180: 68 6C A2   return HPA control to automatic mode
index 181: D0 03 ...  TPS65185/VCOM setup
```

关键点：

- `64 74 01` 必须在 EDID 写完以后执行。
- HPD 需要保持低电平足够长，当前状态机使用约 1 秒低电平、约 0.5 秒高电平，便于 Windows 和 HDMI 发射端丢弃旧 EDID 缓存。
- 完成 HPD 重新枚举后，再将 HPA 恢复自动控制。
- 不要将成功版本的 `68 6C A2` 随意改成其他值，也不要删除 HPD 脉冲。

本项目曾经使用过不同的手动 HPA 释放顺序，结果是 FPGA 内部看起来完成配置，但电脑仍保留旧的 1080p 模式。最终以原始工程已验证的 `64 74 01 -> 98 20 F0 -> 68 6C A2` 尾序为准。

## 6. 构建和 JTAG 验证流程

### 6.1 构建

使用当前工程的 Vivado 2026.1：

```powershell
& 'D:\FPGA_IDE\2026.1\Vivado\bin\vivado.bat' `
  -mode batch `
  -source 'build\build_es120mc1_jtag_diagnostic.tcl' `
  -nolog -nojournal
```

构建成功的判据：

```text
impl_1 status: ... Complete
DRC errors: 0
write_bitstream completed
```

### 6.2 JTAG 下载

确认 JTAG 已连接、`hw_server` 在 `localhost:3121` 监听，然后执行：

```powershell
& 'D:\FPGA_IDE\2026.1\Vivado\bin\vivado.bat' `
  -mode batch `
  -source 'build\inspect_edid_ila_jtag.tcl' `
  -nolog -nojournal
```

该流程只下载 FPGA bitstream，不改写 NAND。

### 6.3 Windows 侧验证

验证顺序：

1. HDMI 线保持连接，避免在验证期间让显示器设备消失。
2. 下载 bitstream 后等待 ADV7611 完成配置和 HPD 脉冲。
3. 检查 Windows 显示设置中的分辨率和刷新率。
4. 检查显示器是否重新枚举为新的 `DISPLAY\\EPDxxxx` 实例。
5. 从注册表回读原始 EDID，确认 DTD 和校验和，而不是只看 Windows 界面。

可使用以下 PowerShell 片段回读当前 ES120MC1 的基础 EDID：

```powershell
$dev = Get-PnpDevice -PresentOnly -Class Monitor |
  Where-Object { $_.FriendlyName -eq 'Generic Monitor (ES120MC1)' } |
  Select-Object -First 1

$code = ($dev.InstanceId -split '\\')[1]
$path = "HKLM:\SYSTEM\CurrentControlSet\Enum\DISPLAY\$code\*\Device Parameters"
$p = Get-Item $path | Select-Object -First 1
$edid = [byte[]]$p.GetValue('EDID')

$dtd = ($edid[54..71] | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
$sum = (([int[]]$edid[0..127] | Measure-Object -Sum).Sum % 256)

[PSCustomObject]@{
    Instance = $dev.InstanceId
    DTD = $dtd
    Checksum = $sum
    PixelClockMHz = ([int]$edid[54] + 256 * [int]$edid[55]) / 100.0
}
```

对于本次成功基线，必须得到：

```text
DTD:
2B 2D 5A A0 A0 40 2E 60 30 80 36 00 03 A2 10 00 00 1E

Checksum: 0
PixelClockMHz: 115.63
```

## 7. 故障定位顺序

### 仍然显示 1920x1080@60Hz

按以下顺序检查：

1. 确认 HDMI 线在 bitstream 下载和 HPD 脉冲期间保持连接。
2. 确认 Windows 是否出现新的 `DISPLAY\\EPDxxxx` 实例。
3. 回读注册表 EDID，确认不是旧实例的缓存内容。
4. 确认 byte `0x7F` 校验和为 0。
5. 确认 `64 74 01 -> 98 20 F0 -> 68 6C A2` 尾序没有被改动。
6. 确认 ADV7611 I2C 写入没有 ACK 错误。
7. 确认源码、bitstream 和实际下载文件是同一次构建产物。

### EDID 正确但 HDMI 图像仍然异常

这属于下一阶段问题，不应与 EDID 枚举混在一起。需要单独检查：

- ADV7611 输出的实际 pix_clk、HS、VS、DE；
- 输入分辨率是否超过 ADV7611 和板级时钟链路能力；
- HDMI 采集到 DDR 的写地址和帧边界；
- 读帧与写帧是否发生撕裂；
- ES120MC1 的行列方向、扫描时序和波形参数。

本文件只记录 EDID 配置和验证基线，不代表 HDMI 到墨水屏的完整显示链路已经完成。

## 8. 当前第一阶段基线文件

```text
源码:
controller/Eink_controller_V1.0/Eink_controller_V1.0.srcs/sources_1/new/config_reg_es120mc1.v
controller/Eink_controller_V1.0/Eink_controller_V1.0.srcs/sources_1/new/adv7611_iic_manager.v

构建脚本:
build/build_es120mc1_jtag_diagnostic.tcl

下载脚本:
build/inspect_edid_ila_jtag.tcl

验证 bitstream:
build/es120mc1_jtag_diagnostic/EBAZ4205_ES120MC1_EDID_DIAGNOSTIC.bit
```

后续修改 EDID 时，应先复制并保留本基线，再只修改 DTD、范围描述符和校验和，最后通过 JTAG 验证；在 EDID 验证完成前，不要引入 HDMI 图像处理链路或 NAND 烧写变量。
