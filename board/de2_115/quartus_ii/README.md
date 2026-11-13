# DE2-115 双端口 MII 交换机

`es_switch_de2_115_top`：Cyclone IV E `EP4CE115F29C7` 上的双端口 100 Mbit/s
全双工 MII 交换机，固定 `NUM_PORTS=2`、`CLK_FREQ_HZ=50_000_000`。板级壳只是
一张引脚表加 PHY 管理，交换逻辑来自同一个 `es_switch_mii` 分级流水线；板级
不再有任何监控、指示或运行期配置路径。

## 1. 构建步骤

工程为 Quartus II 项目（`ethernet_switch.qpf` / `.qsf` / `de2_115.sdc`）。在
Windows 上直接用 `build.bat`：

```bat
build.bat                          :: 自动探测 Quartus 并完整编译
build.bat C:\altera\13.1\quartus   :: 指定安装根目录，跳过探测
build.bat clean                    :: 删除 db/、output_files/、报告等产物
```

或把 Quartus 加入 `PATH` 后：

```
quartus_sh --flow compile ethernet_switch
```

`build.bat` 要求带 Cyclone IV E 器件库的 Quartus II 13.0sp1 / 13.1 Web
Edition，或 Quartus Prime 18.1 及更早版本（19.1 起移除了 Cyclone IV E）。
产物在 `output_files/ethernet_switch.sof` 与 `.sta.rpt`。

`.qsf` 固定 `TOP_LEVEL_ENTITY es_switch_de2_115_top`、宏 `SYNTHESIS=1`、
`SEARCH_PATH ../../../rtl`，并逐项列出全部 RTL 源文件——RTL 直接从仓库编译，
没有需要同步的源码副本。Quartus 前端与其余三个工具不同：模块级循环必须包在
显式 `generate ... endgenerate` 中，genvar 要单独声明，注释行不能以
`synthesis` 等词开头，elaboration 期表格要用函数计算而不是 `initial` 块。

## 2. 引脚、时钟与复位

| 项 | 设置 |
|---|---|
| 器件 | `EP4CE115F29C7`（Cyclone IV E），JP1 置于 MII 位置 |
| 内核时钟 | `CLOCK_50` @ `PIN_Y2`，3.3-V LVTTL，50 MHz，唯一时钟域 |
| 复位 | `KEY[0]` @ `PIN_M23`，2.5 V，低有效；经两级同步器产生 `rst_ni` |
| 其余按键 | `KEY[3:1]` 未接入逻辑，仅作 `unused_*` 哑元消费 |
| ENET 引脚 | 两路 88E1111 的 `RX_DATA/RX_DV/RX_ER`、`TX_DATA/TX_EN/TX_ER`，2.5 V Bank；具体编号见 `.qsf` |
| MDIO | `ENET0/1_MDC`、`ENET0/1_MDIO`(inout, `tri logic`)，需外部上拉 |
| PHY 复位 | `ENET0/1_RESET_N` 跟随同步后的 `rst_ni`，无额外最短脉宽或晶振稳定延时 |
| 中断 | `ENET0/1_INT_N` 未使用 |

50 MHz 下 100 Mbit/s 端口的 `BYTE_PERIOD = 4`：每个八位组 4 个内核时钟，是
MII 串行器要求的偶数窗口。两路 `ENET*_TX_CLK` 由 `negedge CLOCK_50` 上的
翻转寄存器二分频得到（25 MHz）；`de2_115.sdc` 以 `-edges {2 4 6}` 把它们声明为
`clk_50` 的生成时钟，并对 PHY 驱动的 RX/MDIO/INT 输入设 `set_false_path`（这些
信号与 `clk_50` 异步，是板级壳的已知单时钟限制），对 TX 数据按 `tx_clk0/1`
设 max 5.000 ns / min 0.000 ns 输出延迟。

## 3. PHY 管理

两片 Marvell 88E1111 各由一个 `es_perips_phy_88e1111`（Clause 22 MDIO 轮询）
管理；板级信号 `phy_enabled` 直接接到交换核的 `link_up_i`，即只有 PHY 报告
有效链路时该端口才注入字节。管理器的状态字节、中断与闲置按键没有监控去处，
统一汇入 `unused_board` 哑元消费。

注意：本板级壳不包含消抖、上电初始化保证或 PHY 复位保持计时；MDIO 焊盘依赖
板上（或测试台里的）弱上拉，否则管理器读到高阻会停在其管理错误状态。
`ENET*_MDC` 由管理器驱动，无 PHY 从机时不会完成链路发现。

## 4. 板级自检 TB 与 `phy_enabled` force

`hdl/tb_es_switch_de2_115_top.sv` 由 `make board-unit` 运行，用两个独立的
`sw_mii_if` 线模型在打包的 MII 半字节引脚上驱动**完整线上帧**（前导/SFD +
client + FCS），并在出线侧按 `sw_tb_pkg` 独立重组、校验前导与 FCS。

关键限制：测试台**没有外部 MDIO PHY 从机模型**。管理器仅 `RESET_WAIT_MS`
就要 20 ms 内核时钟，且无响应时读回上拉电平、停在管理错误状态，
`phy_enabled`（也就是 `link_up_i`）不会在实用仿真时间内拉高；而 `link_up_i`
会门控 RX 注入，不拉高就一帧也转发不了。

因此这个 bench：

1. 先观察并打印 `u_dut.phy_enabled`（X/Z-free 检查），诚实报告未观测到自然
   MDIO 链路建立；
2. 随后显式 `force u_dut.phy_enabled = 2'b11`，**绕过** PHY 管理，跑一次广播
   smoke（ENET0 → ENET1，校验无源端口回环、线模型收到的帧长度/MAC/EtherType/
   FCS/前导），并做降级检查：TX_EN 曾被拉高、观察到的输出无 X/Z、`TX_ER`
   恒低、MDIO 焊盘处于上拉电平；
3. `release` 后以显式错误计数和 `$fatal` / `$finish` 结束。

**这个 force 是刻意绕过 MDIO 管理，不是对 MDIO 管理的验证。** 它证明的是
MII 引脚 → 交换核 → 引脚这条通路在链路建立后确实能转发；MDIO 管理本身需要
带 PHY 从机模型的板级集成来验证。

## 5. 门禁

板级顶层纳入 `make lint` / `make rtl` / `make synth` 的五个顶层之列，
`make board-unit` 运行上面的自检。Windows 下经 WSL：

```sh
bash wsl.sh "make lint"
bash wsl.sh "make rtl"
bash wsl.sh "make synth"
bash wsl.sh "make board-unit"
```

`make synth` 不在 `make all` 内，需单独执行。板级时序与 PHY 适配的未完成项
见 `de2_115.sdc` 与 `AGENTS.md`。
