# Run in Vivado Tcl Console, or: vivado -mode batch -source configure.tcl
# Reuses the existing project and never resets its runs or changes its part.
set board_dir [file dirname [file normalize [info script]]]
set project_file [file join $board_dir vivado.xpr]
if {[current_project -quiet] eq ""} {
    open_project $project_file
} elseif {[file normalize [get_property DIRECTORY [current_project]]] ne $board_dir} {
    error "A different project is open; close it before sourcing configure.tcl"
}
set rtl_dir [file normalize [file join $board_dir ../../rtl]]
set source_files [concat [glob [file join $rtl_dir *.sv]] \
    [list [file join $board_dir hdl sw_vivado_top.sv]]]
foreach source_file $source_files {
    if {[llength [get_files -quiet $source_file]] == 0} {
        add_files -norecurse -fileset sources_1 $source_file
    }
    set_property file_type SystemVerilog [get_files $source_file]
}
# sw_defs is compilation-unit declarations included by every module.
set_property file_type {Verilog Header} [get_files [file join $rtl_dir sw_defs.sv]]
set dirs [get_property include_dirs [get_filesets sources_1]]
if {[lsearch -exact $dirs $rtl_dir] < 0} { lappend dirs $rtl_dir }
set_property include_dirs $dirs [get_filesets sources_1]
set_property top_auto_set false [get_filesets sources_1]
set_property top sw_vivado_top [get_filesets sources_1]
set sim_set [get_filesets -quiet sim_1]
if {[llength $sim_set] != 0} {
    set_property top_auto_set false $sim_set
    set_property top sw_vivado_top $sim_set
}
foreach name {pins timing} {
    set xdc_file [file join $board_dir constraints ${name}.xdc]
    if {[llength [get_files -quiet $xdc_file]] == 0} {
        add_files -norecurse -fileset constrs_1 $xdc_file
    }
}
update_compile_order -fileset sources_1
puts "Configured sw_vivado_top; pin/PHY timing templates remain incomplete."
puts "If an earlier core-top run exists, reset_run synth_1 and rerun synthesis before implementation."
