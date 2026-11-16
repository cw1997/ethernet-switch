# ethernet-switch

一个用可综合 SystemVerilog 编写的参数化以太网二层交换机，核心是建立在 **8bit 字节流边界上的五级帧级并发流水线**，配有自校验回归，以及一条基于 LibreLane 3.0（OpenLane 2）直到 GDSII 的物理实现流程。

[English](README.md) | **简体中文**

通用 RTL 默认 **4 端口**（可用参数改写）；DE2-115 板级壳是 **2 端口**，Vivado 模板是 **8 端口**。设计按 `rtl/common/`、`rtl/mac/`、`rtl/mems/`、`rtl/perips/`、`rtl/switch/` 分域组织，`rtl/es_defs.sv` 是按依赖顺序汇总各声明库的总头文件。整个设计没有任何监控、统计、命令或指示路径。

---

## 目录

[1 边界](#1-mac-接口) · [2 流水线](#2-五级流水线) · [3 丢弃规则](#3-帧准入和丢弃规则) · [4 CAM](#4-cam-行为) · [5 五个顶层](#5-五个顶层模块) · [6 参数](#6-参数) · [7 端口](#7-端口与速率模型) · [8 仓库结构](#8-仓库结构) · [9 门禁](#9-构建门禁与验证) · [10 硬约束](#10-rtl-硬约束) · [11 板级与流程](#11-板级壳与物理流程) · [12 旧版差异](#12-与旧版本差异) · [13 已知限制](#13-已知限制)

---

## 1. MAC 接口

每口使用带 `sof/eof/err` 的 8 位 `valid/ready` 字节流。接收 MAC 识别前导码和 SFD，并在 EOF 提供原始 32 位 FCS，首个 FCS 字节在最低 8 位。发送 MAC 生成前导码、必要填充、FCS 和帧间隔。交换核心使用一个时钟，PHY 符号速率由 MAC 适配。

## 2. 五级流水线

1. **`es_switch_stage_1_rx`** 每个入端在 SOF 预留字节及描述符空间，在 EOF 或确认错误时发布描述符。错误后停写，继续吞掉剩余字节。SOF 时空间不足由 MAC 整帧丢弃。
2. **`es_switch_stage_2_validate`** 并行检查帧头和长度。拒绝时将转发长度置零，保留实际入队字节数。
3. **`es_switch_stage_3_checksum`** 随 RX 写入累积 CRC32，再与原始 FCS 比较。失败时保留用于顺序回收的字节数。
4. **`es_switch_stage_4_lookup`** 仅为合法帧查询和学习 CAM，按顺序回收非法帧和无目标帧。整帧轮询一次预留全部目标及所需空间，目标不重叠的帧可以并行复制。
5. **`es_switch_stage_5_tx`** 在 EOF 写入后提交整帧，上一帧发送时可复制下一帧。

背压期间描述符保持稳定。Payload 保存在入端字节队列中，由复制引擎按描述符顺序读取。慢速出端可能推迟广播复制，但各出端可以独立发送已经提交的整帧。

## 3. 帧准入和丢弃规则

`MIN_FRAME_LEN` 和 `MAX_FRAME_LEN` 从目的 MAC 开始计到最后一个负载或填充字节，排除 FCS。默认最短长度为 60 字节，达到配置上限且收到 EOF 的帧仍可接受。

拒绝条件包括接收错误、帧长超界、首个 VLAN 标签头截断、组播或广播源地址、源或目的等于入端本机地址、源和目的相同、任一地址全零，以及 Length/Type 的 1501–1535 区间。无标签 802.3 帧的实收长度须等于 60 与「14 加声明长度」两者中的较大值。FCS 通过后才允许操作 CAM。

## 4. CAM 行为

* `NUM_PORTS` 路组合查找与 `NUM_PORTS` 路学习**同拍**完成。查找是 **read-first**：同一拍写入的学习对这一拍的查找不可见。
* `CAM_SETS × CAM_WAYS` 个表项；桶哈希是纯 XOR 折叠（无乘法器、无除法器、无宽加法链），桶选择用常量索引的优先级 mux；组相联并带 round-robin 替换指针。精确命中就地表项重定位，不推进指针。
* 若同一拍落在同一 bucket 的学习多于 `NUM_WAYS`，由 `learn_ready_o` 对超额者反压一拍；`cam_stage` 会保持 `valid` 直到学习被批准。**禁止静默丢弃学习**。
* 并行度由 `NUM_PORTS` 决定：每端口一路 CAM 查、一路学，Stage 4 每个源端口一个搬运引擎（各自读自己的入口字节 FIFO），没有单独的 lane 数旋钮。桶选择用常量索引优先级 mux，哈希为纯 XOR 折叠，以保证 `synth -flatten` 可完成。

## 5. 五个顶层模块

三个接口顶层命名为 `es_*_top` 并位于 `rtl/`；两个板级顶层保持原名。`lint`、`rtl`、`synth` 都会 elaboration **全部五个**，任何一个从不被编译的 wrapper 都无法悄悄腐烂。

| 顶层 | 接口 | 例化位置 | 说明 |
|---|---|---|---|
| `es_gmii_top` | GMII，8bit 引脚 | ASIC / 默认 | LibreLane 的 `DESIGN_NAME` |
| `es_mii_top` | MII，4bit 半字节 | DE2-115 板级壳 | 1000 Mbit/s 端口在 elaboration 时报错 |
| `es_rmii_top` | RMII，2bit 双比特 | — | 拒绝 1000 Mbit/s，且要求 `BYTE_PERIOD` 可整除 |
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
| `MIN_FRAME_LEN` | 60 | 接受的最小 client 字节数 |
| `MAX_FRAME_LEN` | 1518 | 接受的最大 client 字节数 |
| `SLOTS` | 2 | 每入口缓冲的帧槽数 |
| `SLOT_BYTES` | 2048 | 每槽字节数，入端总容量为 SLOTS×SLOT_BYTES |
| `DESC_DEPTH` | 8 | descriptor FIFO 深度 |
| `TX_QUEUE_DEPTH` | 256 | 每端口 TX FIFO 的配置下限 |
| `CAM_SETS` | 128 | CAM 组数 |
| `CAM_WAYS` | 4 | 每组路数 |
| `LEARNING_EN` | 1 | 使能源地址学习 |
| `FLOOD_MODE` | `2'd1` | 洪泛策略（见下） |
| `IFG_OCTETS` | 12 | 帧间隔八位组数 |

**仿真与综合的默认几何不同。** 上表是**仿真**默认值。定义 `SYNTHESIS` 时（`make synth` 与 LibreLane 都会定义），`es_switch_pl_defs.sv` 提供一组缩小几何：`MAX_FRAME_LEN=256`、`SLOTS=1`、`SLOT_BYTES=512`、`TX_QUEUE_DEPTH=64`、`CAM_SETS=16`、`CAM_WAYS=2`。实际 TX 深度为 max(TX_QUEUE_DEPTH, 2 × MAX_FRAME_LEN)，综合为每口 512 字节，完整仿真默认值为每口 3036 字节。LibreLane 另在 `SYNTH_PARAMETERS` 中重申同一组缩小值。

`FLOOD_MODE`：**0** = 只转发广播；**1** = 同时洪泛未知单播（默认）；**2** = 连未知组播/组地址也洪泛。`LEARNING_EN` 与 `FLOOD_MODE` 是纯 elaboration 参数，没有任何运行期配置路径。

## 7. 端口与速率模型

字节流握手形如 `<src>_o_valid/<src>_o_ready` ↔ `<dst>_i_valid/<dst>_i_ready`；RX 侧带 `sof/eof/err`，TX 侧带 `sof/eof`。GMII 顶层端口为 `clk_i`、`rst_ni`、`link_up_i[N]`、`gmii_rx_en_i[N]`、`gmii_rx_data_i[N*8]`、`gmii_tx_en_o[N]`、`gmii_tx_data_o[N*8]`；MII / RMII 顶层把数据总线换成各自的半字节/双比特引脚及 RX_ER 信号。

每个端口只需要一个 elaboration 常量：`BYTE_PERIOD = sw_byte_period(CLK_FREQ_HZ, PORT_SPEED[p])`，即一个八位组占多少个 `clk_i` 周期。125 MHz 下分别为 1（1000BASE-T）、10（100BASE-TX）、100（10BASE-T）；50 MHz 的 100 Mbit/s 端口为 4。线速用**时钟使能**表达，而不是另起时钟域——全设计单时钟、无跨时钟域。

## 8. 仓库结构

```
rtl/common/     CRC-32、DFF / pipe-stage 原语
rtl/mac/        字节流成帧器、GMII/MII/RMII 适配器、串行器
rtl/mems/       FWFT FIFO、1R1W RAM、并行寄存器堆
rtl/perips/     MDIO 与 88E1111 PHY 管理
rtl/*.sv        三个接口顶层：es_gmii_top / es_mii_top / es_rmii_top
rtl/switch/     五级流水线、CAM 和 fabric
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

本次是数据通路的完全改写。旧版的宽位数据通路、全局单帧仲裁，以及与之配套的全部监控／状态／命令／指示路径已整体移除，代之以上面的字节流帧级并发流水线。配置现在纯粹是 elaboration 期参数（`FLOOD_MODE`、`LEARNING_EN`），`link_up_i` 仅作数据门控。三个接口顶层现命名为 `es_gmii_top` / `es_mii_top` / `es_rmii_top`，两个板级顶层保持原名。

## 13. 已知限制

* LibreLane 构建 elaboration 的是一个**缩小版**实例（`SYNTH_PARAMETERS`）：它证明流程在可完成的规模下能读、能综合、能布线，并不表示全尺寸配置已经布局布线完成；本文也不声称 GDSII 已经流片。
* Vivado 板级壳的物理 PHY 时钟捕获、CDC 与时序适配明确**未完成**；`make vivado` 回归只建模同步 MII 边界，不测真实 PHY CDC 或板级时序。
* DE2-115 板级 TB 绕过 MDIO 管理（`phy_enabled` 被 force），该 bench 不验证 PHY 管理。
* `make synth` 用本机 yosys，未必与 LibreLane 镜像内的版本一致，因此两者的单元数/面积数字会有差异。
