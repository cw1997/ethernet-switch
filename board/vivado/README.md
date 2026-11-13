# Vivado 八端口 MII 模板

`es_switch_vivado_top`：面向 `xc7k160tffg676-3` 的八端口固定 100 Mbit/s
MII 板级骨架，50 MHz 系统时钟，138 个端口位。设计是纯交换逻辑，没有监控、
指示或运行期配置路径。**这是通用适配模板，不能直接连接真实 PHY 或下载上板。**

## 1. 工程与 `configure.tcl`

现有 `vivado.xpr` 由 Vivado 2026.1 创建，请用能读取该工程并支持目标器件的
版本。在仓库根目录的 Vivado Tcl Console 执行：

```tcl
source board/vivado/configure.tcl
```

或在配置好 Vivado 环境的终端：

```sh
vivado -mode batch -source board/vivado/configure.tcl
```

`configure.tcl` 以脚本自身路径锚定工程目录，重复执行不会重复添加文件或
include 路径，且保留器件、run 策略与已有 run 产物。它做四件事：

1. 用 `glob` 重新登记 `rtl/*.sv` 与 `rtl/*/*.sv`，加上
   `hdl/es_switch_vivado_top.sv`；只移除已失效的仓库管理源节点，保留无关的
   工程文件，并把所有 `*defs.sv` 标为 `Verilog Header`。
2. 关闭自动顶层选择（`top_auto_set false`），把设计视图 `sources_1` 和仿真
   视图 `sim_1` 的顶层都固定为 `es_switch_vivado_top`。
3. 附加 `constraints/pins.xdc` 与 `constraints/timing.xdc`（引脚占位保持注释，
   仅 20 ns 系统时钟约束生效），保留 UCIO-1/NSTD-1 的 DRC 严重级别。
4. `update_compile_order -fileset sources_1` 解析依赖关系。

脚本**不会** `reset_run`：配置是可重复的，丢弃缓存 checkpoint 是另一项显式
动作。若工程里还留着早期以内部核心顶层跑出的 `synth_1` 结果，先
`close_design`、`reset_run synth_1`，再 `launch_runs synth_1` 重跑综合，
不能复用旧的 `.dcp`。

## 2. `.xpr` 源节点已清理

仓库管理源列表中的陈旧节点已从 `vivado.xpr` 清除，脚本每次重新用 `glob`
附着当前分级流水线 RTL。旧状态曾让实现误把内部核心顶层当成物理顶层，产生
I/O 数量不匹配；现在设计/仿真顶层都固定为 `es_switch_vivado_top`，
自动顶层选择已关闭。修正顶层并不补全物理引脚与 PHY 时序——接板要求见下。

## 3. 顶层连接

| 信号 | 说明 |
|---|---|
| `clk_i` | 50 MHz 单端系统时钟；差分晶振需另加输入缓冲 |
| `rst_button_ni` | 异步低有效按钮，经两级带 `ASYNC_REG` 的触发器同步；不含消抖，不假设上电初值，配置后需保持低电平至少三个上升沿再释放 |
| `mii_rx_clk_i[7:0]` / `mii_tx_clk_i[7:0]` | PHY 驱动的时钟输入，当前仅预留、不驱动任何逻辑；不得接到 FPGA 输出时钟 |
| `mii_rxd_i[31:0]` / `mii_txd_o[31:0]` | 端口 p(0–7) 占 `[4*p +: 4]`，低位半字节在前 |
| `mii_rx_dv_i/er_i[7:0]`、`mii_tx_en_o/er_o[7:0]` | 按端口号索引的状态位；`mii_tx_er_o` 恒低 |
| `phy_reset_no[7:0]` | 跟随同步复位，不额外延长脉冲 |
| `phy_mdc_o[7:0]` / `phy_mdio_io[7:0]` | MDC 固定低、MDIO 始终高阻，需要板上外部上拉；无 MDIO 管理事务 |
| `link_up_i` | 模板无管理控制器，八端口在壳内固定拉高 |

Vivado 在 `default_nettype none` 下要求显式声明输入端口种类，因此 RTL 输入用
`input var logic`、双向 MDIO 用显式 `tri logic` 网络。

## 4. 物理 PHY 适配未完成

以下是明确的**未完成板级工作**，模板没有声称它们已被解决：

1. 按原理图填写每个信号的 `PACKAGE_PIN` / `IOSTANDARD`，核对 Bank VCCO、
   PHY I/O 电压与时钟引脚能力；模板不猜测任何真实引脚。
2. 实现每端口 PHY RX/TX 时钟捕获与 CDC。当前是把同步 MII 模型直接接到
   `es_switch_mii`；简单同步各数据位或忽略 PHY 时钟不能保证多位一致性和
   持续线速接收。
3. 按所选 PHY 实现复位保持、时钟稳定等待、上电初始化、速率配置与链路检测；
   按钮同步链不替代 PHY 上电/复位时序。
4. 填写八端口外部时钟、输入延迟、输出 setup/hold 预算，确认采样/发射边沿，
   检查 `report_cdc`、`check_timing`、`report_timing_summary`；不要用全局
   false path 掩盖缺失逻辑。`timing.xdc` 里 PHY 相关示例全部是注释占位。

前导码/SFD 识别、FCS 校验与生成、pad 与 IFG 都由 `rtl/mac/` 的字节流适配器
完成，不属于这里待补的 PHY 工作。预留的 PHY 时钟、未驱动的 MDIO 与固定为
低的 MDC 会产生预期的综合告警。

## 5. 八端口 MII 自检 TB

`hdl/tb_es_switch_vivado_top.sv` 由 `make vivado` 运行，不需要安装 Vivado。
八个独立的 `sw_mii_if` 线模型驱动完整线上帧，并在出线侧按 `sw_tb_pkg`
独立重组、校验前导与 FCS；`BYTE_PERIOD = 4`（50 MHz / 100 Mbit/s），
`link_up_i` 固定拉高，预留的 PHY 时钟接低。

场景：复位/空闲检查；从最高端口广播，验证跨 7 → 0 环回边界泛洪且不回送源
端口；一次学习广播把站点登记到端口 0；随后从端口 7 发已知单播，只应到端口
0（再次覆盖环回边界）。它检查按钮同步、PHY 复位、MDIO 高阻与 MDC 空闲。

该回归**不验证真实 PHY CDC、板级时序或硬件多时钟域**；线模型只是同步 MII
边界的独立参考。每个检查打印 PASS/FAIL，带超时看门狗、显式错误计数和
`$fatal`/`$finish`。

## 6. 门禁

板级顶层纳入 `make lint` / `make rtl` / `make synth` 的五个顶层之列；

```sh
ci/check-toolchain.sh
make lint
make rtl
make synth
make vivado
```

Windows 下统一用 `bash wsl.sh "make vivado"` 这类形式。`make synth` 不在
`make all` 内，需单独执行。工程规范见 [AGENTS.md](../../AGENTS.md)，交换核
说明见 [中文 README](../../README.zh-Hans.md)。
