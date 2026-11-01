# 方案:新增 `sw_mii` / `sw_rmii` 适配模块,宏切换顶层 MAC 接口

## 目标与决策

- 新增两个独立模块 `rtl/sw_mii.sv`、`rtl/sw_rmii.sv`,把 MII(4-bit nibble)和 RMII(2-bit 块)引脚适配成核心现有的 8-bit octet 流。
- `sw_switch` 用编译宏三选一:`SW_IF_MII` / `SW_IF_RMII`,**都不定义时默认 GMII**(完全向后兼容,现有 tb / GDS 流程不受影响)。
- 已确认:① 内部 octet 流接口从中性命名(改掉 gmii_* 误称);② 节奏用整除约束 + `$error`,不做分数调度;③ 完整接入回归与 CI。
- 遵循仓库既有约定:单时钟域、无 PHY 时钟引脚的同步模型(符号按 `sw_byte_period` 节奏呈现,CDC 属于板级外壳,与 `sw_switch.sv` 头部契约一致)。

## 1. 内部规范接口改名 oct_*

契约本身不变(每 BYTE_PERIOD 拍一个 octet、en 整窗有效、数据整窗稳定、IFG 期间 en 至少一拍为低;RX 无 preamble、TX 含 preamble+FCS):

- `sw_rx_port`:`gmii_en_i/gmii_d_i` → `oct_en_i/oct_d_i`
- `sw_tx_port`:`gmii_en_o/gmii_d_o` → `oct_en_o/oct_d_o`
- `sw_gmii_rx`:`gmii_en_i/gmii_d_i` → `oct_en_i/oct_d_i`(模块名不变,头注释同步)
- `sw_gmii_tx`:`gmii_en_o/gmii_d_o` → `oct_en_o/oct_d_o`(模块名不变,头注释同步)
- 现有 tb 全部只连 `sw_switch` 顶层 GMII 引脚,**零改动**。

## 2. 新模块 rtl/sw_mii.sv

- 参数:`BYTE_PERIOD`(核心时钟拍数/octet,必须为偶数)。
- 引脚侧:`mii_rx_dv_i`、`mii_rx_er_i`、`mii_rxd_i[3:0]`;`mii_tx_en_o`、`mii_tx_er_o`(恒 0)、`mii_txd_o[3:0]`。
- 核心侧:`oct_en_o/oct_d_o[7:0]`(RX,进 `sw_rx_port`)、`oct_en_i/oct_d_i[7:0]`(TX,来自 `sw_tx_port`)。
- **RX**:自由跑动 NPK=BYTE_PERIOD/2 相位计数器,在偶数窗末采样低 nibble、奇数窗末采样高 nibble(MII 低 nibble 在前),拼成 octet 后在 octet 窗口起点寄存输出——整窗稳定、与 `sw_gmii_rx` 的栅格末拍采样对齐(引入一个 octet 时间延迟,store-and-forward 不受影响)。`mii_rx_er_i` 在帧内出现 → 粘性标志抑制整帧(en 输出保持低)。
- **TX**:与 `sw_gmii_tx` 同一栅格(octet 只在栅格边界变化):前半窗输出低 nibble、后半窗输出高 nibble,en 组合直通(与 `sw_gmii_tx` 的组合 en 同理,注释说明)。
- `` `ifndef SYNTHESIS `` 检查:BYTE_PERIOD 为偶数且 ≥2,否则 `$error`。

## 3. 新模块 rtl/sw_rmii.sv

- 结构同上,4 块/octet(CPK=BYTE_PERIOD/4,低 2-bit 块在前),参数必须为 4 的倍数。
- 引脚侧:`rmii_crs_dv_i`(按 RX_DV 语义使用,全双工交换忽略纯载波 sense,注释说明)、`rmii_rxd_i[1:0]`;`rmii_tx_en_o`、`rmii_txd_o[1:0]`。RMII 规范无 RX_ER,不做错误输入(帧错误由 FCS 兜底)。
- 注释注明:真实 RMII 10M 的"符号重复 10 次"不建模,速率适配属外部外壳。

## 4. sw_switch 宏切换

- 顶层端口用**嵌套 `` `ifdef ``(不用 `` `elsif ``,对 yosys 前端最保守),三选一:
  - MII:`mii_rx_dv_i[NUM_PORTS]`、`mii_rx_er_i[NUM_PORTS]`、`mii_rxd_i[4*NUM_PORTS]`、`mii_tx_en_o`、`mii_tx_er_o`、`mii_txd_o[4*NUM_PORTS]`
  - RMII:`rmii_crs_dv_i[NUM_PORTS]`、`rmii_rxd_i[2*NUM_PORTS]`、`rmii_tx_en_o`、`rmii_txd_o[2*NUM_PORTS]`
  - 默认:现有 `gmii_rx_en_i/gmii_rx_data_i/gmii_tx_en_o/gmii_tx_data_o` 不动。
- 内部新增 `rx_oct_en/rx_oct_data/tx_oct_en/tx_oct_data` nets;GMII 分支用 4 条 `assign` 直连,MII/RMII 分支在 `g_port` generate 内实例化适配器;`u_rx`/`u_tx` 的连线三种模式完全一致。
- `` `ifndef SYNTHESIS `` 检查追加:MII/RMII 模式下任一端口 `PORT_SPEED == SW_SPEED_1000M` 则 `$error`。
- 头部"PHY interface contract"注释改写为三模式 + 规范 octet 流描述。

## 5. 测试(全部自检、PASS/FAIL 计数、$finish)

- `tb/sw_mii_tb.sv`、`tb/sw_rmii_tb.sv`:单元级。RX 组包顺序、en 窗口节奏、帧尾/IFG 行为、RX_ER 抑制(仅 MII)、TX nibble/chunk 序列化与 en 对齐;含边界实例(MII BP=2、RMII BP=4 即每拍一块)。
- `tb/tb_sw_switch_mii.sv`:系统冒烟,`-DSW_IF_MII` 编译。2 端口、125 MHz、100M(BP=10→nibble 5 拍),单播 + 泛洪 + FCS 校验(复用 `sw_tb_pkg` 的 CRC)。
- `tb/tb_sw_switch_rmii.sv`:系统冒烟,`-DSW_IF_RMII` 编译。2 端口、50 MHz(RMII 标准 REF_CLK),port0=100M(BP=4→每拍一块)、port1=10M(BP=40→10 拍/块),双向帧 + FCS。

## 6. 构建 / CI / 流程注册

- **Makefile**:`RTL_SRCS` 加两个新文件;`make lint` 跑三遍(默认、`-DSW_IF_MII`、`-DSW_IF_RMII`,约 3 s);新增 `mii`、`rmii` target(各自:单元 tb + 系统 tb,系统 tb 带 `-D` 宏),加进 `.PHONY` 和 `all`;`YOSYS_SCRIPT` 的 `-DSYNTHESIS` 提为可覆盖变量 `YOSYS_DEFINES ?= -DSYNTHESIS`(保持单行),便于 `make synth YOSYS_DEFINES="-DSYNTHESIS -DSW_IF_MII"`;头注释同步。
- **librelane/config.json**:`VERILOG_FILES` 加两个新文件(GDS 流程保持 GMII 默认,`VERILOG_DEFINES` 不动;`io.sdc` 不动);改动记入 `librelane/README.md`。
- **ci.yml**:test job 增加 `make mii`、`make rmii` 两步。
- **README.md**:记录三种模式、宏名、整除约束(RMII@100M 需 50/100 MHz 核心时钟)、新 target、同步模型假设。
- **AGENTS.md**:§5 门禁列表补 `make mii` / `make rmii` 两行。

## 7. 实施顺序

1. oct_* 改名(4 个 RTL 文件,机械替换)→ `make lint/rtl/unit/sim/param` 全绿。
2. 写 `sw_mii.sv` + 单元 tb → `make lint` + 单元跑通;同法 `sw_rmii.sv`。
3. `sw_switch` 宏切换 + 系统 tb。
4. Makefile / config.json / ci.yml / README / AGENTS 注册。
5. 全量验证:`ci/check-toolchain.sh`、`make lint`(3 变体)、`make rtl`、`make unit`、`make mii`、`make rmii`、`make sim`、`make param`、`make synth`,另跑一次 `make synth YOSYS_DEFINES="-DSYNTHESIS -DSW_IF_MII"` 与 RMII 变体确认合成前端接受宏分支。

## 风险与边界

- MII/RMII 模式下 1000M 端口被 elaboration `$error` 拒绝;RMII@100M 在 125 MHz 核心时钟被整除约束拒绝(用 50/100 MHz)。
- 不支持 `` `elsif ``、不引入新 `initial` 块(仅 `` `ifndef SYNTHESIS `` 检查)、不新增 `lint_off`;新常量无需进 `sw_defs.sv`(NPK/CPK 均为模块内 localparam)。
- RGMII 不在本次范围;将来增加只需新模块 + 一个新的 `` `ifdef `` 分支。