# ethernet-switch

一个用可综合 SystemVerilog 编写的参数化以太网二层交换机，核心是建立在 **8bit 字节流边界上的五级帧级并发流水线**，配有自校验回归，以及一条基于 LibreLane 3.0（OpenLane 2）直到 GDSII 的物理实现流程。

[English](README.md) | **简体中文**

通用 RTL 默认 **4 端口**（可用参数改写）；DE2-115 板级壳是 **2 端口**，Vivado 模板是 **8 端口**。设计按 `rtl/common/`、`rtl/mac/`、`rtl/mems/`、`rtl/perips/`、`rtl/switch/` 分域组织，`rtl/es_defs.sv` 是按依赖顺序汇总各声明库的总头文件。整个设计没有任何监控、统计、命令或指示路径。

---

## 目录

[1 边界](#1-唯一重要的边界) · [2 流水线](#2-五级流水线架构) · [3 丢弃规则](#3-帧准入与八类异形包丢弃) · [4 CAM](#4-cam-行为) · [5 五个顶层](#5-五个顶层模块) · [6 参数](#6-参数) · [7 端口](#7-端口与速率模型) · [8 仓库结构](#8-仓库结构) · [9 门禁](#9-构建门禁与验证) · [10 硬约束](#10-rtl-硬约束) · [11 板级与流程](#11-板级壳与物理流程) · [12 旧版差异](#12-与旧版本差异) · [13 已知限制](#13-已知限制)

---

## 1. 唯一重要的边界

`rtl/mac/` 与 `rtl/switch/` 之间只有一条刻意收窄的契约：**8bit 字节流**，带 `valid/ready` 握手和 `sof/eof/err` 边带信号。交换核只见 **MAC client 数据**——没有前导码、SFD、FCS 或帧间隔。线路相关的一切都在 `rtl/mac/`：

* RX 成帧器自行搜索 **7 × 0x55 + 0xD5**（不假设 PHY 已剥掉前导码），并校验 CRC-32 FCS；
* TX 成帧器生成前导码/SFD、补齐短帧、重算 FCS、插入帧间隔；
* MII / RMII 适配器复用半字节/双比特串行器还原八位组流，时钟使能速率模型也在这一层。

因此 `es_switch_fabric` 完全不含时钟使能、线速或符号顺序知识；换一个 MAC 去例化它，边界以下的代码一行都不用改。`link_up_i` 只是**数据门控**，不是可观测接口。

## 2. 五级流水线架构

旧版那种「整个交换结构一次只搬一帧」的全局仲裁器已经取消。现在每一级都可以同时驻留一帧，并且 `NUM_PORTS` 个接收引擎并行工作。级间由 `es_common_pipe_stage` 连接（`valid/ready` 寄存器，带 `DP` 与 `CUT_READY` 参数）。

| 级 | 模块 | 职责 |
|---|---|---|
| S0/S1 | `es_switch_rx_engine`（=`es_switch_rx_ctrl` + `es_switch_rx_parse` + `es_switch_rx_check`）+ `es_switch_frame_buf` | 每拍一个字节、头部锁存、八类丢弃检查（纯组合）、每端口字节 FIFO + descriptor FIFO、合法帧描述符 |
| S2 | `es_switch_cam_stage` + `es_switch_cam_table` | **同拍**完成 `NUM_PORTS` 路目的查找与 `NUM_PORTS` 路源学习 |
| S3 | `es_switch_decide` | 广播/组播/未知单播策略、源端口过滤、生成 egress mask |
| S4 | `es_switch_tx_writer` | 每个源端口一个搬运引擎，读各自的帧槽；目标写口按「编号最小者胜出」仲裁 |
| S5 | `es_switch_tx_engine` | 每端口 TX 队列；随后由 MAC 适配器重新生成前导码、pad、FCS 和 IFG |

保持各级无损、且能被四种工具综合的不变量：

* 一帧只有在**完整收齐且通过全部检查**之后才对下游可见。坏帧或超 MTU 帧用 **单拍 `undo` 脉冲**把字节 FIFO 写指针回卷掉已写字节，不产生描述符。
* **`SLOTS * SLOT_BYTES` 必须是 2 的幂**。回卷是在 `ADDR_W` 位指针上做 `wr_ptr - undo_cnt`，而 `next_slot` 会跳过非 2ⁿ 深度的非法编码；两者混用会落到非法编码上。`es_switch_frame_buf` 在 elaboration 阶段检查这一点。
* 级间载荷是 **packed** `{}` 向量，宽度用 `localparam`、字段偏移用 `es_switch_pl_defs.sv` 中的函数；不用 struct、interface 或 package。一次传输只在握手成立时发生，因此反压永远不会丢字节。
* egress mask 为零的帧**不会**在 S3 被丢弃：TX writer 仍会逐字节把它读空，保证下一个描述符从正确的偏移开始。

## 3. 帧准入与八类异形包丢弃

`MIN_FRAME_LEN` / `MAX_FRAME_LEN` 约束的是 MAC client 字节数（不含前导码/SFD 与 FCS）。只有当字节 FIFO 能容纳一整帧最大长度、且 descriptor FIFO 有空位时，一帧才被准入；准入后 `b_ready_o` 整帧保持有效。八类丢弃规则：

| # | 类别 | 判定位置 |
|---|---|---|
| 1 | FCS 错 / RX_ER / 截断（`b_err_i` 裁决） | MAC 适配器裁决，RX 引擎消费 |
| 2 | runt（短于 `MIN_FRAME_LEN`） | RX 引擎 |
| 3 | 超 MTU（长于 `MAX_FRAME_LEN`） | RX 引擎（把线上剩余字节排空） |
| 4 | 802.3 length 字段与实测 client 长度不符 | RX 引擎 |
| 5 | VLAN tag 在内层 EtherType 之前残缺 | RX 引擎 |
| 6 | 源 MAC 为组播/广播地址 | RX 引擎 |
| 7 | 源 MAC 等于本端口 MAC | RX 引擎 |
| 8 | 目的 MAC 等于本端口 MAC | RX 引擎 |

FCS **只在 MAC 适配器校验一次**，RX 引擎只消费裁决结果，因此同一批字节上 CRC LFSR 不会被例化两遍。

## 4. CAM 行为

* `NUM_PORTS` 路组合查找与 `NUM_PORTS` 路学习**同拍**完成。查找是 **read-first**：同一拍写入的学习对这一拍的查找不可见。
* `CAM_SETS × CAM_WAYS` 个表项；桶哈希是纯 XOR 折叠（无乘法器、无除法器、无宽加法链），桶选择用常量索引的优先级 mux；组相联并带 round-robin 替换指针。精确命中就地表项重定位，不推进指针。
* 若同一拍落在同一 bucket 的学习多于 `NUM_WAYS`，由 `learn_ready_o` 对超额者反压一拍；`cam_stage` 会保持 `valid` 直到学习被批准。**禁止静默丢弃学习**。
* 并行度由 `NUM_PORTS` 决定：每端口一路 CAM 查、一路学，`es_switch_tx_writer` 每个源端口一个搬运引擎（各自读自己的入口字节 FIFO），没有单独的 lane 数旋钮。桶选择用常量索引优先级 mux，哈希为纯 XOR 折叠，以保证 `synth -flatten` 可完成。

## 5. 五个顶层模块

五个顶层名保持不变。`lint`、`rtl`、`synth` 都会 elaboration **全部五个**，任何一个从不被编译的 wrapper 都无法悄悄腐烂。

| 顶层 | 接口 | 例化位置 | 说明 |
|---|---|---|---|
| `es_switch_gmii` | GMII，8bit 引脚 | ASIC / 默认 | LibreLane 的 `DESIGN_NAME` |
| `es_switch_mii` | MII，4bit 半字节 | DE2-115 板级壳 | 1000 Mbit/s 端口在 elaboration 时报错 |
| `es_switch_rmii` | RMII，2bit 双比特 | — | 拒绝 1000 Mbit/s，且要求 `BYTE_PERIOD` 可整除 |
| `es_switch_de2_115_top` | 2 × MII PHY 引脚 | Quartus II 板级 | 50 MHz、100 Mbit/s、MDIO PHY 管理 |
| `es_switch_vivado_top` | 8 × MII 模板 | Vivado 板级 | 50 MHz、100 Mbit/s，`link_up_i` 固定拉高 |

## 6. 参数

三个 wrapper 暴露同一套配置接口（板级壳把其中若干项固定为 `localparam`）：

| 参数 | 默认值 | 含义 |
|---|---|---|
| `NUM_PORTS` | 4 | 端口数 |
| `CLK_FREQ_HZ` | GMII 125 MHz / MII、RMII 50 MHz | 核心时钟频率 |
| `PORT_SPEED` | GMII `2'd2` / MII、RMII `2'd1` | 每端口 `sw_speed_e`，packed `N*2` 位 |
| `PORT_MAC` | `'0` | 每端口 MAC，packed `N*48`；为零则派生本地地址 |
| `MIN_FRAME_LEN` | 64 | 接受的最小 client 字节数 |
| `MAX_FRAME_LEN` | 1518 | 接受的最大 client 字节数 |
| `SLOTS` | 2 | 每入口缓冲的帧槽数 |
| `SLOT_BYTES` | 2048 | 每槽字节数；`SLOTS*SLOT_BYTES` 必须是 2ⁿ |
| `DESC_DEPTH` | 8 | descriptor FIFO 深度 |
| `TX_QUEUE_DEPTH` | 256 | 每端口 TX FIFO 深度 |
| `CAM_SETS` | 128 | CAM 组数 |
| `CAM_WAYS` | 4 | 每组路数 |
| `LEARNING_EN` | 1 | 使能源地址学习 |
| `FLOOD_MODE` | `2'd1` | 洪泛策略（见下） |
| `IFG_OCTETS` | 12 | 帧间隔八位组数 |

**仿真与综合的默认几何不同。** 上表是**仿真**默认值。定义 `SYNTHESIS` 时（`make synth` 与 LibreLane 都会定义），`es_switch_pl_defs.sv` 提供一组缩小几何：`MAX_FRAME_LEN=256`、`SLOTS=1`、`SLOT_BYTES=512`、`TX_QUEUE_DEPTH=64`、`CAM_SETS=16`、`CAM_WAYS=2`。全尺寸帧缓冲为 4×2048×8 ≈ 13 万触发器，yosys 的 `synth -flatten` 需要几十分钟才能展开；综合门禁只需证明前端能读入并 elaboration。仿真仍用完整默认值，因此行为测试没有被削弱。LibreLane 另在 `SYNTH_PARAMETERS` 中重申同一组缩小值。

`FLOOD_MODE`：**0** = 只转发广播；**1** = 同时洪泛未知单播（默认）；**2** = 连未知组播/组地址也洪泛。`LEARNING_EN` 与 `FLOOD_MODE` 是纯 elaboration 参数，没有任何运行期配置路径。

## 7. 端口与速率模型

字节流握手形如 `<src>_o_valid/<src>_o_ready` ↔ `<dst>_i_valid/<dst>_i_ready`；RX 侧带 `sof/eof/err`，TX 侧带 `sof/eof`。GMII 顶层端口为 `clk_i`、`rst_ni`、`link_up_i[N]`、`gmii_rx_en_i[N]`、`gmii_rx_data_i[N*8]`、`gmii_tx_en_o[N]`、`gmii_tx_data_o[N*8]`；MII / RMII 顶层把数据总线换成各自的半字节/双比特引脚及 RX_ER 信号。

每个端口只需要一个 elaboration 常量：`BYTE_PERIOD = sw_byte_period(CLK_FREQ_HZ, PORT_SPEED[p])`，即一个八位组占多少个 `clk_i` 周期。125 MHz 下分别为 1（1000BASE-T）、10（100BASE-TX）、100（10BASE-T）；50 MHz 的 100 Mbit/s 端口为 4。线速用**时钟使能**表达，而不是另起时钟域——全设计单时钟、无跨时钟域。

## 8. 仓库结构

```
rtl/common/     两级采样器、CRC-32、DFF / pipe-stage 原语
rtl/mac/        字节流成帧器、GMII/MII/RMII 适配器、串行器
rtl/mems/       FWFT FIFO、1R1W RAM、并行寄存器堆
rtl/perips/     MDIO 与 88E1111 PHY 管理
rtl/switch/     分级结构：rx_engine（ctrl/parse/check 三片）、frame_buf、
                cam_stage/table、decide、tx_writer、tx_engine、fabric、三个 wrapper
tb/             自校验回归（不综合、不进 CI lint）
board/          DE2-115（Quartus II）与 Vivado 8 口 MII 板级壳，各带一个 TB
ci/             工具链契约（check-toolchain.sh）
librelane/      config.json + constraints/io.sdc + 流程 README
Makefile        全部门禁；target 清单写在文件头
AGENTS.md       RTL / TB / 流程的权威规则
```

## 9. 构建、门禁与验证

按下列顺序执行，次序是按「多快能失败」排的。

```sh
ci/check-toolchain.sh   # 工具版本与门禁所假设的一致
make lint               # Verilator -Wall，任何告警即失败
make rtl                # Icarus 仅 RTL elaboration，五个顶层
make unit               # 模块级 + 分级结构回归
make mii rmii vivado board-unit   # 四个 PHY / 板级前端
make sim                # GMII 系统回归，完整线上帧
make param              # 3 端口、非 2ⁿ CAM（96 × 3）
make param-scan         # 4/8/16/32/48 端口 × CAM 组合
make synth              # yosys，需 PATH 中有 yosys，不在 `make all` 里
make all                # 以上除 `synth` 之外的全部
```

| 门禁 | 工具 | 独有作用 |
|---|---|---|
| `make lint` | Verilator `--lint-only -Wall` | 位宽不匹配、未用信号、锁存器、case 覆盖不全；任何告警即失败 |
| `make rtl` | Icarus `-g2012`，仅 RTL | 只有靠 TB 顺手声明某个信号才能 elaboration 的设计 |
| `make unit` / `sim` / `param` | Icarus + `vvp` | 行为 |
| `make synth` | yosys `read_verilog -sv` | 仿真器放行、硅流程不放行的写法 |
| CI `gds` job | LibreLane 3.0.14，sky130A | 标准单元下的时序、hold、DRC、LVS |

`make param-scan` 覆盖端口数 **4/8/16/32/48** 与 CAM 组合 `(16,2) (96,3) (64,1) (32,4) (128,4) (64,2) (48,5)`，七种组合都跑完整场景套件并通过。扫描抽样的是**几何组合**而非场景——把场景、端口数与每一组 CAM set/way 做完整叉乘会超出 CI 时间预算。

**`make all` 不含 `make synth`**——收尾前必须单独跑一次，它是唯一能强制综合限制的门禁。CI 跑在 **self-hosted** Linux runner 上，四个 job：`images`、`lint`、`test`、`gds`，LibreLane 版本 **3.0.14**；`gds` job 需要人工审批。Windows 下 EDA 工具在 WSL 里，所有命令都包一层：

```sh
bash wsl.sh "make lint"
bash wsl.sh "make synth"
```

CI 直接用 Linux 跑 make，不需要 `wsl.sh`。完成标准见 `AGENTS.md` §5：不新增 `verilator lint_off`、不新增 `initial` 块、上述门禁全绿。

## 10. RTL 硬约束

这些不是风格偏好；其中几条是因为「另一种写法」已经以 TB 看不出来的方式坑过这个设计。

* **yosys 三禁令**：（1）禁止 `package` 与任何形式的 `import`，共享声明放在 `es_defs.sv` 的 compilation-unit 作用域；（2）任何函数禁止 `return`，改为对函数名赋值（IEEE 1800-2017 13.3）；（3）`read_verilog` **必须**带 `-sv`，`.sv` 扩展名不等于启用 SystemVerilog。三条对 Icarus / Verilator 都不可见。
* **Verilator `-Wall` 零告警，且不新增 `lint_off` 豁免**：修代码而不是压告警。命令行上的 `-Wno-DECLFILENAME` 是约定，不是被掩盖的缺陷。
* **复位是同步、低有效、命名 `rst_ni`**，且是每个带状态 `always_ff` 的第一个分支；全设计无异步复位。
* **运行期索引的对象一律用 packed vector**：Icarus 对运行期索引的 unpacked 数组会返回陈旧数据；unpacked 数组只用于常量索引的存储器/寄存器堆。
* **寄存器堆由 generate 循环里的 per-entry `always_ff` 写入**，索引为常量，绝不用循环索引存储。
* elaboration 期参数检查用 `` `ifndef SYNTHESIS `` 内的 `$error` / `$warning`，因为 yosys 没有这些系统任务的实现。
* 算术/位运算的每个操作数宽度一致且就是想要的宽度；`always_comb` 先给所有输出赋值、每个 `case` 都带 `default`；Quartus 需要显式 `generate`、单独声明的 genvar、用函数计算 elaboration 期表格。完整规则见 `AGENTS.md`。

## 11. 板级壳与物理流程

* **DE2-115** — `board/de2_115/quartus_ii/README.md`：双口 100 Mbit/s MII、50 MHz、经 MDIO 管理 88E1111 PHY、KEY0 复位、TX_CLK 分频。其板级 TB 因为没有外部 MDIO PHY 从机模型，`force` 了 `phy_enabled` 以绕过 MDIO 管理，**不验证 MDIO 管理**。
* **Vivado** — `board/vivado/README.md`：8 口 MII 模板。`configure.tcl` 用 `glob` 重新附着 RTL，`.xpr` 里的陈旧源节点已清理；物理 PHY 时钟捕获与 CDC 仍是未完成的板级集成工作。
* **LibreLane** — `librelane/README.md`：`config.json`、`SYNTH_PARAMETERS` 变更记录、`io.sdc`、2.4 → 3.0 迁移表，以及 CI `gds` 审批门。

## 12. 与旧版本差异

本次是数据通路的完全改写。旧版的宽位数据通路、全局单帧仲裁，以及与之配套的全部监控／状态／命令／指示路径已整体移除，代之以上面的字节流帧级并发流水线。配置现在纯粹是 elaboration 期参数（`FLOOD_MODE`、`LEARNING_EN`），`link_up_i` 仅作数据门控。五个顶层名保持不变。

## 13. 已知限制

* LibreLane 构建 elaboration 的是一个**缩小版**实例（`SYNTH_PARAMETERS`）：它证明流程在可完成的规模下能读、能综合、能布线，并不表示全尺寸配置已经布局布线完成；本文也不声称 GDSII 已经流片。
* Vivado 板级壳的物理 PHY 时钟捕获、CDC 与时序适配明确**未完成**；`make vivado` 回归只建模同步 MII 边界，不测真实 PHY CDC 或板级时序。
* DE2-115 板级 TB 绕过 MDIO 管理（`phy_enabled` 被 force），该 bench 不验证 PHY 管理。
* `make synth` 用本机 yosys，未必与 LibreLane 镜像内的版本一致，因此两者的单元数/面积数字会有差异。
