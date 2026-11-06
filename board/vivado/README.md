# Vivado 八端口 MII 网口模板

为 `xc7k160tffg676-3` 提供八个固定 100 Mbps 端口的板级骨架，系统时钟为
50 MHz。这是通用适配模板，**不能直接连接真实 PHY 或下载上板**。

## 环境与使用

现有 `vivado.xpr` 由 Vivado 2026.1 创建；请使用能读取该工程并支持目标器件的版本。
在仓库根目录启动 Vivado Tcl Console，执行：

```tcl
source board/vivado/configure.tcl
```

也可在配置好 Vivado 环境的终端执行：

```sh
vivado -mode batch -source board/vivado/configure.tcl
```

脚本重复执行不会重复添加文件，保留工程器件和已有运行设置。可直接打开
`vivado.xpr`，设计顶层为 `es_switch_vivado_top`。约束分为 `constraints/pins.xdc`
和 `constraints/timing.xdc`：仅 20 ns 系统时钟约束生效，所有管脚、电压及
PHY 时序占位均为注释，不会把占位符传给 Vivado。

配置后可在 Tcl Console 检查综合和时钟约束：

```tcl
synth_design -no_timing_driven -top es_switch_vivado_top -part xc7k160tffg676-3
report_clocks
report_utilization
```

模板综合检查关闭时序驱动优化以减少运行时间，不代表时序收敛。完成实际 PHY
适配及完整约束后，使用默认综合、实现和时序分析检查可上板性。
预留的 PHY 时钟、未驱动的 MDIO 和固定为低的 MDC 会产生预期的综合告警。

## 排查 507 个 I/O 的放置错误

如果出现 `[Place 30-415]`，且报告列出 `stat_o[447:0]`，说明实现使用了
`es_switch_mii` 核心顶层。其默认四端口加上统计／控制总线共 507 个端口位；
板级顶层 `es_switch_vivado_top` 只有 138 个端口位，统计总线保留在 FPGA 内部。

在已经打开此工程的 Vivado Tcl Console 中执行：

```tcl
source [file join [get_property DIRECTORY [current_project]] configure.tcl]
# Close any old synthesized/implemented design before discarding run products.
if {[current_design -quiet] ne ""} { close_design }
reset_run synth_1
launch_runs synth_1 -jobs 4
wait_on_run synth_1
```

`reset_run synth_1` 会清除可重新生成的综合结果并重置依赖它的实现运行。
综合成功后再启动实现，不能继续使用旧的 `es_switch_mii.dcp`。
配置脚本将设计和仿真顶层固定为 `es_switch_vivado_top`，关闭自动顶层选择；若另一个
Vivado 窗口仍打开旧工程状态，应在那个窗口也重新执行配置脚本，避免旧设置再次保存。
修正顶层并不补全模板中的物理引脚和 PHY 时序，接板要求仍见下文。

## 顶层连接

- `clk_i`：50 MHz 单端系统时钟输入；差分晶振需要另加适当输入缓冲。
- `rst_button_ni`：低有效按钮，经两级带 `ASYNC_REG` 属性的触发器同步。
  不假设上电初值；配置后先保持按钮低电平至少三个时钟上升沿，再释放。
  复位按下和释放都需两个采样沿传播，核心在后续上升沿采样同步复位。
- `mii_rx_clk_i[7:0]`、`mii_tx_clk_i[7:0]`：PHY 驱动的时钟输入，当前仅预留，
  不驱动核心逻辑；不得连接到 FPGA 输出时钟。
- `mii_rxd_i[31:0]`、`mii_rx_dv_i[7:0]`、`mii_rx_er_i[7:0]`：接收数据和状态。
  `mii_txd_o[31:0]`、`mii_tx_en_o[7:0]`、`mii_tx_er_o[7:0]`：发送数据和状态。
  端口 p（0–7）对应数据位 `[4*p +: 4]`；状态位按端口号索引。
- `phy_reset_no[7:0]`：跟随同步复位的低有效 PHY 复位，不额外延长脉冲。
- `phy_mdc_o[7:0]` 固定为低；`phy_mdio_io[7:0]` 始终高阻，需板上外部上拉。
  没有 MDIO 管理、自动协商监测或动态速率切换，八端口逻辑使能始终有效。

FPGA 的这些信号连接 PHY 数字侧；RJ45 通过 PHY 及相应磁性器件连接，不能直接接 FPGA。

## 接板前必须完成

1. 根据板卡原理图填写每个管脚的 `PACKAGE_PIN` 和 `IOSTANDARD`，检查 Bank
   VCCO、PHY I/O 电压和时钟管脚能力；模板不猜测任何真实管脚。
2. 实现每端口 PHY RX/TX 时钟适配及 CDC。当前直接连接到 `es_switch_mii`
   的同步模型：每个半字节保持两个核心周期，从 RX_DV 上升开始按连续窗口送入。
   简单同步各数据位或忽略 PHY 时钟不能保证多位数据一致性和持续线速接收。
3. 在 RX 路径识别并去除真实线上的前导码和 SFD，保留目的 MAC 起始的帧及 FCS。
   现有核心 TX 已生成前导码、SFD 和 FCS；发送适配还需保证 MII TX_CLK 对齐和帧间隔。
4. 根据所选 PHY 实现复位保持时间、时钟稳定等待、上电初始化、速率配置和链路检测。
   模板按钮同步不含消抖，不能替代 PHY 上电／复位时序控制。
5. 根据 PHY 数据手册和 PCB 延迟填写八端口外部时钟、输入延迟及输出 setup/hold
   预算，确认发射／采样边沿。添加准确的 CDC 约束并检查 `report_cdc`、
   `check_timing` 和 `report_timing_summary`，不能用全局 false path 掩盖缺失逻辑。

模板保留 UCIO-1、NSTD-1 等 DRC 的默认严重级别。不完整的管脚约束会阻止正常
bitstream 生成；填写引脚也不代表上述 PHY 适配和时序工作已经完成。

## 开发验证

在 Linux／WSL 工具链环境中，从仓库根目录执行：

```sh
ci/check-toolchain.sh
make lint
make rtl
make unit
make param
make sim
make synth
make vivado
```

`make vivado` 是 Icarus 板级模板回归，无需安装 Vivado，并已纳入 `make unit` 和 `make all`。
它检查按钮同步、PHY 复位、MDIO 高阻、MDC 空闲，以及 50 MHz 同步接口模型下
的全端口泛洪、环形已知单播、学习和独立线模型重组得到的 FCS。该回归不验证真实 PHY CDC 或板级时序。
新顶层同时纳入 lint、RTL elaboration 和 yosys 综合检查。

仓库工程规范见 [AGENTS.md](../../AGENTS.md)，交换核心说明见
[中文 README](../../README.zh-Hans.md)。

Vivado 在 `default_nettype none` 下要求显式声明输入端口种类。因此 RTL 模块输入
采用 `input var logic`，MDIO 采用显式 `tri logic` 网络；这些声明保留核心行为和隐式网络检查。
