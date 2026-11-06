# ============================================================================
# File        : configure.tcl
# Description : Reattach the Vivado board template, shared RTL and both XDC
#               files to the existing project without changing its device,
#               run strategies or generated run products.
#
#               Source this file in Vivado Tcl Console, or from this directory:
#                   vivado -mode batch -source configure.tcl
#               Paths are anchored to the script, not the console's working
#               directory. Repeated calls must not duplicate files or includes.
#
#               This configures a project; it does not make the generic PHY
#               wiring ready for hardware. Rebuild stale core-top runs before
#               implementation, and fill physical constraints for a real board.
# ============================================================================

# ---- select the intended project --------------------------------------------
# Reject an open project rooted in another directory before adding files. The
# directory check allows the script to repair this board project in its GUI.
set board_dir [file dirname [file normalize [info script]]]
set project_file [file join $board_dir vivado.xpr]
if {[current_project -quiet] eq ""} {
    open_project $project_file
} elseif {[file normalize [get_property DIRECTORY [current_project]]] ne $board_dir} {
    error "A different project is open; close it before sourcing configure.tcl"
}
# ---- source registration and SystemVerilog parsing ---------------------------
# Register all rtl/ blocks so a future wrapper dependency is not omitted from
# the project. Compile-order analysis below chooses the reachable hierarchy;
# this source list does not select a different physical top.
set rtl_dir [file normalize [file join $board_dir ../../rtl]]
set source_files [concat [glob [file join $rtl_dir *.sv]] [glob [file join $rtl_dir * *.sv]] \
    [list [file join $board_dir hdl es_switch_vivado_top.sv]]]
# Remove only stale repository-managed sources; preserve unrelated project files.
foreach existing [get_files -quiet -of_objects [get_filesets sources_1]] {
    set normalized [file normalize $existing]
    if {![file exists $normalized] && ([string first $rtl_dir $normalized] == 0 || [string first [file join $board_dir hdl] $normalized] == 0)} {
        remove_files $existing
    }
}
foreach source_file $source_files {
    # Reuse existing file objects; duplicate copies can be compiled with
    # different types/include paths and produce misleading redefinition errors.
    if {[llength [get_files -quiet $source_file]] == 0} {
        add_files -norecurse -fileset sources_1 $source_file
    }
    set_property file_type SystemVerilog [get_files $source_file]
}
# es_defs contains compilation-unit declarations included by every module,
# not a separately elaborated design unit. Treat it as a header after setting
# the module files to SystemVerilog; keep the existing include search entries.
foreach header [concat [glob [file join $rtl_dir *defs.sv]] [glob [file join $rtl_dir * *defs.sv]]] {
    set_property file_type {Verilog Header} [get_files $header]
}
set dirs [get_property include_dirs [get_filesets sources_1]]
if {[lsearch -exact $dirs $rtl_dir] < 0} { lappend dirs $rtl_dir }
set_property include_dirs $dirs [get_filesets sources_1]
# ---- physical hierarchy selection -------------------------------------------
# The bare es_switch_mii core exports a 448-bit statistics bus. Automatic top
# selection can therefore produce hundreds of package pins instead of the
# board template's 138 bits. Disable automatic selection in both file sets so
# the design and simulation views explicitly use the same board hierarchy.
set_property top_auto_set false [get_filesets sources_1]
set_property top es_switch_vivado_top [get_filesets sources_1]
set sim_set [get_filesets -quiet sim_1]
if {[llength $sim_set] != 0} {
    set_property top_auto_set false $sim_set
    set_property top es_switch_vivado_top $sim_set
}
# ---- constraints and dependency ordering ------------------------------------
# Pin placeholders remain commented and only the system clock is active.
# Adding these XDCs must not lower UCIO-1/NSTD-1 or invent PHY delay budgets.
foreach name {pins timing} {
    set xdc_file [file join $board_dir constraints ${name}.xdc]
    if {[llength [get_files -quiet $xdc_file]] == 0} {
        add_files -norecurse -fileset constrs_1 $xdc_file
    }
}
# Resolve includes and module dependencies only after files/types/top are fixed.
# Do not reset runs here: configuration is repeatable, while discarding cached
# checkpoints is a separate, explicit rebuild action documented in README.md.
update_compile_order -fileset sources_1
puts "Configured es_switch_vivado_top; pin/PHY timing templates remain incomplete."
puts "If an earlier core-top run exists, reset_run synth_1 and rerun synthesis before implementation."
