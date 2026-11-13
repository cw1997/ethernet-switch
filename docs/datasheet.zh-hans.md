# es-switch 数据手册

参数化以太网二层交换核心，8bit 字节流边界上的五级帧级并发流水线，单时钟域、
同步低有效复位。MAC 适配器负责前导/SFD/FCS/pad/IFG，交换核只见 MAC client
数据。本文描述可综合 RTL 的接口与行为，不是流片实测报告。

## 1. 参数表

三个通用 wrapper 共用同一套顶层参数；两个板级 top 把部分项固定为 `localparam`。

| 参数 | 类型 / 位宽 | 默认值 | 说明 |
|---|---|---|---|
| `NUM_PORTS` | `int unsigned` | 4 | 端口数，所有宽度由此派生 |
| `CLK_FREQ_HZ` | `int unsigned` | GMII 125_000_000；MII/RMII 50_000_000 | 核心时钟频率 |
| `PORT_SPEED` | `logic [N*2-1:0]` | GMII `{N{2'd2}}`；MII/RMII `{N{2'd1}}` | 每端口速率枚举 `sw_speed_e`（0=10M、1=100M、2=1000M、3=down） |
| `PORT_MAC` | `logic [N*48-1:0]` | `'0` | 每端口 MAC；为零时由 `sw_default_mac(PORT_ID)` 派生本地地址 |
| `MIN_FRAME_LEN` | `int unsigned` | 64 | 接受的最小 MAC client 字节数 |
| `MAX_FRAME_LEN` | `int unsigned` | 1518 | 接受的最大 MAC client 字节数 |
| `SLOTS` | `int unsigned` | 2 | 每入口缓冲的帧槽数 |
| `SLOT_BYTES` | `int unsigned` | 2048 | 每槽字节数；`SLOTS*SLOT_BYTES` **必须是 2 的幂** |
| `DESC_DEPTH` | `int unsigned` | 8 | 描述符 FIFO 深度（≥2） |
| `TX_QUEUE_DEPTH` | `int unsigned` | 256 | 每端口 TX FIFO 深度（≥2） |
| `CAM_SETS` | `int unsigned` | 128 | CAM 组数 |
| `CAM_WAYS` | `int unsigned` | 4 | 每组路数 |
| `LEARNING_EN` | `int unsigned` | 1 | 0 关闭源地址学习 |
| `FLOOD_MODE` | `logic [1:0]` | `2'd1` | 0=只广播；1=洪泛未知单播；2=也洪泛未知组播 |
| `IFG_OCTETS` | `int unsigned` | 12 | 帧间隔八位组数 |

`FLOOD_MODE` 与 `LEARNING_EN` 是纯 elaboration 参数，无运行期配置路径；`link_up_i` 只是数据门控。

上表为**仿真**默认几何。定义 `SYNTHESIS` 时（`make synth` 与 LibreLane 的 `VERILOG_DEFINES`），`es_switch_pl_defs.sv` 改提供缩小默认：`MAX_FRAME_LEN=256`、`SLOTS=1`、`SLOT_BYTES=512`、`TX_QUEUE_DEPTH=64`、`CAM_SETS=16`、`CAM_WAYS=2`（`MIN_FRAME_LEN=64`、`DESC_DEPTH=8` 不变）。原因是全尺寸 4×2048×8 帧缓冲约合 13 万触发器，yosys `synth -flatten` 展开极慢；仿真不定义该宏，故行为回归始终用全尺寸。LibreLane 的 `SYNTH_PARAMETERS` 与这组值一致。

## 2. 端口表

### 2.1 内部字节流边界（MAC 适配器 ↔ 交换核）

| 信号 | 方向 | 位宽 | 说明 |
|---|---|---|---|
| `clk_i` | in | 1 | 单一时钟 |
| `rst_ni` | in | 1 | 同步低有效复位 |
| `link_up_i` | in | `[N-1:0]` | 数据门控；down 端口不能注入字节 |
| `rx_valid_i` / `rx_ready_o` | in / out | `[N-1:0]` | 接收握手，反压无损 |
| `rx_data_i` | in | `[N*8-1:0]` | 每端口一个八位组 |
| `rx_sof_i` / `rx_eof_i` / `rx_err_i` | in | `[N-1:0]` | 帧边界与 FCS/RX_ER/截断裁决 |
| `tx_valid_o` / `tx_ready_i` | out / in | `[N-1:0]` | 发送握手 |
| `tx_data_o` | out | `[N*8-1:0]` | 每端口一个八位组 |
| `tx_sof_o` / `tx_eof_o` | out | `[N-1:0]` | 帧边界 |

### 2.2 各 top 的物理端口

| Top | 输入 | 输出 |
|---|---|---|
| `es_switch_gmii` | `clk_i`、`rst_ni`、`link_up_i[N]`、`gmii_rx_en_i[N]`、`gmii_rx_data_i[N*8]` | `gmii_tx_en_o[N]`、`gmii_tx_data_o[N*8]` |
| `es_switch_mii` | `mii_rx_dv_i[N]`、`mii_rx_er_i[N]`、`mii_rxd_i[N*4]` | `mii_tx_en_o[N]`、`mii_tx_er_o[N]`、`mii_txd_o[N*4]` |
| `es_switch_rmii` | `rmii_crs_dv_i[N]`、`rmii_rxd_i[N*2]` | `rmii_tx_en_o[N]`、`rmii_txd_o[N*2]` |
| `es_switch_de2_115_top` | `CLOCK_50`、`KEY[3:0]`、两路 `ENET*_RX_*`、`ENET*_MDIO`(inout)、`ENET*_INT_N` | 两路 `ENET*_TX_*`、`ENET*_TX_CLK`、`ENET*_RESET_N`、`ENET*_MDC`、`ENET*_MDIO`(inout) |
| `es_switch_vivado_top` | `clk_i`、`rst_button_ni`、`mii_rx_clk_i[7:0]`、`mii_tx_clk_i[7:0]`、`mii_rxd_i[31:0]`、`mii_rx_dv_i/er_i[7:0]` | `mii_txd_o[31:0]`、`mii_tx_en_o/er_o[7:0]`、`phy_reset_no[7:0]`、`phy_mdc_o[7:0]`、`phy_mdio_io[7:0]`(inout) |

## 3. 性能指标与资源说明

| 项目 | 说明 |
|---|---|
| 内部吞吐 | 每端口每时钟 1 字节，`N` 端口并行即 `N` 字节/clk；级间握手无损；约 5 帧可同时在各级驻留 |
| 线速模型 | `BYTE_PERIOD = sw_byte_period(CLK_FREQ_HZ, PORT_SPEED[p])`，由时钟使能表达；125 MHz 下 1000BASE-T=1、100BASE-TX=10、10BASE-T=100 周期/八位组 |
| 单端口理论线速 | `8 bit × CLK_FREQ_HZ / BYTE_PERIOD`，如 125 MHz / 1 周期 = 1000 Mbit/s；50 MHz / 4 周期 = 100 Mbit/s |
| 帧缓冲 / 队列 | 每入口端口 1 个 `SLOTS*SLOT_BYTES` 字节 FIFO + 1 个 `DESC_DEPTH` 描述符 FIFO（坏帧单拍 `undo` 回卷）；每端口 1 个 `TX_QUEUE_DEPTH` 深 FIFO，字为 `{sof, eof, data[7:0]}` |
| 转发表 | `CAM_SETS × CAM_WAYS` 表项，同拍 `N` 查 + `N` 学；单时钟无 CDC，复位同步低有效 |
| 资源构成 | 存储占主导；`sky130_fd_sc_hd` 无 SRAM 宏，以寄存器 + 读 mux 实现 |
| 物理实现 | LibreLane 用缩小实例 `SYNTH_PARAMETERS`（`MAX_FRAME_LEN=256`、`SLOTS=1`、`SLOT_BYTES=512`、`TX_QUEUE_DEPTH=64`、`CAM_SETS=16`、`CAM_WAYS=2`），`CLOCK_PERIOD=10` |

以上是由参数与结构推导的设计指标，不是硅后实测；`make synth` 的 `stat` 与流程报告才是对应实例的资源数字。

## 4. 异形包丢弃规则（八类）

`MIN_FRAME_LEN` / `MAX_FRAME_LEN` 以 MAC client 字节计（不含前导/SFD/FCS）；帧仅在完整收齐并通过全部检查后才对下游可见，坏帧回卷、不产生描述符。

| # | 丢弃条件 |
|---|---|
| 1 | FCS 错 / RX_ER / 截断（`b_err_i` 裁决，FCS 只在 MAC 适配器校验一次） |
| 2 | runt：`client_len < MIN_FRAME_LEN` |
| 3 | 超 MTU：`client_len > MAX_FRAME_LEN`（继续排空线上剩余字节） |
| 4 | 802.3 length 字段与实测 client 长度不符（`l2type ≤ 1500` 时校验） |
| 5 | VLAN tag 残缺：标记 VLAN 但长度不足 `SW_HDR_LEN_VLAN`(18) |
| 6 | 源 MAC 为组播/广播地址 |
| 7 | 源 MAC 等于本端口 MAC |
| 8 | 目的 MAC 等于本端口 MAC |

## 5. CAM 行为

| 项目 | 行为 |
|---|---|
| 容量 | `CAM_SETS × CAM_WAYS` 表项，`{valid, port, mac}` |
| 并行度 | `NUM_PORTS` 路组合查找 + `NUM_PORTS` 路学习，同拍完成 |
| 语义 | **read-first**：同拍学习对该拍查找不可见；帧查目的 MAC、学自身源 MAC |
| 哈希 | 纯 XOR 折叠六个地址字节（无乘法器/除法器），`SETW=$clog2(NUM_SETS+1)` + 一次条件减法回绕到 `[0, NUM_SETS)`；桶读取用常量索引优先级 mux，不生成宽 `$shiftx` |
| 替换 | 组相联 + round-robin 指针；精确命中就地重定位、不推进指针 |
| 冲突 | 同 bucket 学习多于 `NUM_WAYS` 时 `learn_ready_o` 反压一拍，`cam_stage` 保持 `valid` 直到批准；禁止静默丢弃 |

转发决策（S3）：广播 → 除源端口外全发；组播 → 仅 `FLOOD_MODE=2` 时全发；
单播命中 → 命中掩码去掉源端口；单播未命中 → `FLOOD_MODE≠0` 时全发；源端口始终被过滤。egress mask 为零的帧仍被 TX writer 读空丢弃。

## 6. 五个 top 差异

| Top | 端口数 | 时钟 | 速率 | 管理/门控 | 用途 |
|---|---|---|---|---|---|
| `es_switch_gmii` | 4（默认，可改） | 125 MHz | 1000M | `link_up_i` | ASIC 默认 / LibreLane `DESIGN_NAME` |
| `es_switch_mii` | 4（默认，可改） | 50 MHz | 100M | `link_up_i` | MII 前端；1000M 端口 elaboration 报错 |
| `es_switch_rmii` | 4（默认，可改） | 50 MHz | 100M | `link_up_i` | RMII 前端；拒绝 1000M，`BYTE_PERIOD` 需可整除 |
| `es_switch_de2_115_top` | 2（固定） | 50 MHz | 100M | 88E1111 MDIO 管理 → `phy_enabled` | DE2-115 双口，TX_CLK 分频、KEY0 复位 |
| `es_switch_vivado_top` | 8（固定） | 50 MHz | 100M | `link_up_i` 固定拉高，MDIO 未驱动 | Vivado 8 口 MII 模板 |

五个 top 都进 `lint` / `rtl` / `synth` 门禁；`make sim`/`param`/`param-scan` 覆盖 GMII，`make mii`/`rmii`/`vivado`/`board-unit` 覆盖其余前端与板级。

## 7. 已知限制

* 不提供运行期状态、统计或配置接口；`FLOOD_MODE`/`LEARNING_EN` 只能在 elaboration 时确定。帧缓冲要求 `SLOTS*SLOT_BYTES` 为 2 的幂，且 `MAX_FRAME_LEN` 必须装进 `SW_LEN_W`(11 bit)，否则 elaboration 报错。
* CAM 是哈希组相联、无老化与显式删除；表项只被覆盖或复位清空。
* 板级 PHY 时钟捕获 / CDC / 时序适配未全部完成：Vivado 模板是同步 MII 模型；
  DE2-115 板级 TB 因无外部 MDIO PHY 从机模型而 `force phy_enabled`，**不验证
  MDIO 管理**。
* LibreLane 物理流程跑缩小实例，不能据此声称全尺寸配置已布局布线或已流片；`make synth` 用本机 yosys，与镜像内版本可能不同，资源数字不可直接互换。
