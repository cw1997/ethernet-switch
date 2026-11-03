# DE2-115 Quartus II 工程

把本仓库的以太网交换核心跑到 Terasic **DE2-115** 开发板上的 Quartus II 工程,
双端口 **MII / 100BASE-TX**,连同一条 Windows 一键编译脚本。

## 目录内容

| 文件 | 说明 |
|---|---|
| `ethernet_switch.qpf` | Quartus 工程文件(GUI 从这里打开) |
| `ethernet_switch.qsf` | 工程设置:器件、源文件、引脚、IO 电平、宏 |
| `de2_115.sdc` | TimeQuest 时序约束 |
| `hdl/sw_de2_115_top.sv` | 板级顶层(纯 RTL,无任何厂商原语) |
| `build.bat` | Windows 编译脚本(探测工具 → 完整编译 → PASS/FAIL) |

顶层 `sw_de2_115_top` 实例化 `sw_switch_mii #(.NUM_PORTS(2), .CLK_FREQ_HZ(50_000_000))`,
两个端口固定 100 Mbit/s。它是纯 RTL,因此也被仓库门禁覆盖:
`make lint`、`make rtl`、`make synth` 会把它当作第 4 个顶层一起检查。

## 环境要求

* **Quartus II 13.0sp1 / 13.1 Web Edition**(DE2-115 官方配套版本),或任何仍支持
  Cyclone IV E 的 Quartus(到 Quartus Prime 18.1 为止;19.1 起官方移除了 Cyclone IV)。
* 安装时勾选 **Cyclone IV E 器件库**(缺了它会在 Fitter 阶段才报"器件不存在",
  `build.bat` 的探测会直接把这种安装判为不可用)。
* 与仓库主门禁(Verilator/Icarus/yosys,走 WSL)完全无关;Quartus 只用于这颗
  Cyclone IV。

## 快速开始

命令行(推荐):

```bat
cd board\de2_115\quartus_ii
build.bat                 :: 自动探测 Quartus 并完整编译
build.bat C:\altera\13.1\quartus   :: 指定安装路径
build.bat clean           :: 清理 db\、incremental_db\、output_files\ 等
```

结尾打印 `BUILD PASS`,并在 `output_files\` 下生成 `ethernet_switch.sof`(编程文件)。
失败时打印 `BUILD FAIL` 并提示查看 `output_files\*.rpt`。

GUI 等价操作:双击 `ethernet_switch.qpf` → **Processing → Start Compilation**。

## 板级设置(上电前必看)

| 项目 | 设置 |
|---|---|
| **JP1 跳线** | **MII 模式**(2-3 短接)。出厂默认 RGMII(1-2),不改跳线收发不通 |
| 网口 | ENET0、ENET1 各接一根网线(对端须支持 100M 自协商) |
| KEY[0] | 系统复位(按下保持复位) |
| KEY[1] | 清空 MAC 地址表(每按一次发一个 flush 脉冲) |
| LEDG[0] | 心跳(~1.5 Hz,设计在跑) |
| LEDG[1] | CAM 查表活动(命中/未命中/学习) |
| LEDR[0] / LEDR[1] | RX / TX 流量活动(统计计数器位折叠) |

## 时钟架构

* 核心时钟 = 板上 50 MHz 晶振(`CLOCK_50`)直接驱动,**无 PLL、无厂商原语**。
  核心是单时钟设计(见根 README "One clock, and clock enables instead of clocks"),
  100 Mbit/s 的八位组节拍由 `sw_byte_period(50 MHz, 100M) = 4` 的时钟使能产生。
* MII 要求每端口一个 25 MHz `TX_CLK`,由板级顶层用**负沿翻转触发器**分频产生:
  50% 占空,上升沿与发送数据边沿错开半个周期(10 ns),且该对齐与数据相位无关。
  IEEE 802.3 对 MAC 的建立时间要求是 15 ns;本结构在纯 RTL 下能保证的是
  10 ns,SDC 把它花成"引脚处 ≥5 ns 建立 + ≤5 ns 布线偏斜"交给 TimeQuest 把关,
  取舍细节见 `hdl/sw_de2_115_top.sv` 的注释。

## 引脚分配

全部取自 Terasic / Altera University Program 官方 DE2-115 引脚表
(`DE2_115.qsf`),IO 电平照抄:ENET 组 2.5 V,按键/LED 2.5 V,`CLOCK_50` 3.3-V LVTTL。
注意:

* PHY 复位脚在板上叫 **`ENETx_RESET_N`**(不是 RST_N),已按官方名对齐。
* 器件是 `EP4CE115F29C7`。个别批次的板子焊的是 C8 速度等级——如果下载时报
  JTAG ID 不匹配,把 `.qsf` 里 `DEVICE` 一行改成 `EP4CE115F29C8` 即可。

## 已知限制(如实声明)

1. **只有 10/100 Mbit/s。** DE2-115 的 88E1111 只把 4 位数据线接到 FPGA
   (JP1 在 RGMII/MII 之间选择),物理上不支持完整 8 位 GMII;RGMII 千兆需要
   一个带 DDR IO 和时钟偏移控制的 `sw_rgmii` 适配模块,本仓库还没有。
2. **速度固定 100 M。** 没有 MDIO 管理(MDC 恒低,PHY 保持上电默认:自协商
   开启、MII 模式)。对端自协商结果是 10M 时,RTL 仍按 100M 的节拍收发,帧会
   收错——对端请用千兆/百兆自适应的现代设备。
3. **RX 侧没有异步 FIFO。** PHY 的 RX 数据来自它自己的 RX_CLK,与核心 50 MHz
   异步;顶层直接在核心域采样,这是根 README "The PHY interface" 一节声明的
   板级壳责任,演示/课程场景可用,正式产品需要加 CDC。
4. **TX_CLK 建立时间 10 ns,低于 IEEE 的 15 ns**(见上,取舍写在代码注释里)。

## 验证状态

* `sw_de2_115_top` 已纳入仓库门禁:`make lint / rtl / unit / sim / param / synth`
  全部通过(Verilator -Wall、Icarus、yosys 四个顶层)。
* 在本机的 Quartus Prime Lite 25.1std(无 Cyclone IV 器件库)上验证到
  **Analysis & Synthesis 阶段全绿**:QSF 每个键被接受、全部 RTL 解析并通过
  综合生成网表(`db\ethernet_switch.rtlv_sg_swap.cdb` 检查点)。器件级的
  Fitter/装配/时序分析需要带 Cyclone IV E 器件库的安装,请在目标机器上
  (Quartus II 13.0sp1/13.1 Web Edition)执行 `build.bat` 完成一次完整编译,
  预期产物 `output_files\ethernet_switch.sof`。
* 为了让 RTL 被 Quartus 接受,本仓库顺带修了三处 Quartus 专属的可移植性问题
  (内联 genvar、隐式 generate、以 "synthesis" 开头的注释),并把 CRC 查表从
  `initial` 块改为纯函数(Quartus 对 initial 块初始化的内存病态缓慢,实测
  每实例 27+ CPU 分钟不收敛)。全部规则记录在 `AGENTS.md` §2.4;这些改动
  行为不变,由既有回归证明。
* 已知观察:25.1std 对本设计的 map 后期阶段(状态机处理之后)异常缓慢
  (75+ CPU 分钟未完成);13.1 的解析器/综合器是另一套实现,若在目标机器上
  遇到 map 超长,请把 `output_files\ethernet_switch.map.rpt` 里最后一条
  Elaborating/Processing 信息记录下来再排查。
