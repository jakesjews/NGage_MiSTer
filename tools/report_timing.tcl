# Run after fitting: quartus_sta -t tools/report_timing.tcl
project_open NGage
create_timing_netlist
read_sdc
update_timing_netlist
file mkdir build
report_timing -setup -npaths 30 -nworst 1 -detail full_path -file build/critical-paths.rpt
report_timing -hold -npaths 10 -detail full_path -file build/hold-paths.rpt
report_ucp -file build/unconstrained-paths.rpt
set summary [open build/timing-corners.tsv w]
puts $summary "corner\tcheck\tworst_slack_ns"
set failed 0
# The core does not meet its 104 MHz constraint yet and is released with a
# setup slack of about -1.5 ns (docs/BUILDING.md). NGAGE_SETUP_FLOOR, when
# set (a negative number of ns), is the setup slack down to which this
# script still ends without an error, so that a build server can tell the
# usual state from a real loss. Hold, recovery and removal must not be
# negative either way; without the variable any negative slack is an error.
set setup_floor 0
if {[info exists ::env(NGAGE_SETUP_FLOOR)] && $::env(NGAGE_SETUP_FLOOR) ne ""} {
    set setup_floor $::env(NGAGE_SETUP_FLOOR)
    post_message -type info "setup slack accepted down to $setup_floor ns"
}
# NGage.sdc declares the framework's gated video clock (comb~0) a clock of
# its own. If that node is not the gate in this build, clk_sys keeps the
# gated branch's uncertainty: report it instead of fitting against it.
set sys_clk [get_clocks -nowarn {*|pll|pll_inst|altera_pll_i|*[0].*|divclk}]
foreach_in_collection path [get_timing_paths -setup -npaths 1 -from_clock $sys_clk -to_clock $sys_clk] {
    foreach_in_collection point [get_path_info -required_points $path] {
        if {[get_point_info -type $point] eq "unc"} {
            set unc [expr {abs([get_point_info -incr $point])}]
            post_message -type info "clk_sys setup uncertainty: $unc ns"
            if {$unc > 0.2} {
                post_message -type error "clk_sys carries the gated video clock's uncertainty; see lltune_clk in NGage.sdc"
                set failed 1
            }
        }
    }
}
foreach_in_collection corner [get_available_operating_conditions] {
    set_operating_conditions $corner
    update_timing_netlist
    set name [get_operating_conditions_info -display_name $corner]
    foreach check {setup hold recovery removal} {
        foreach_in_collection path [get_timing_paths -$check -npaths 1] {
            set slack [get_path_info -slack $path]
            puts $summary "$name\t$check\t$slack"
            post_message -type info "$name ${check}: $slack ns"
            if {$slack < ($check eq "setup" ? $setup_floor : 0)} { set failed 1 }
        }
    }
}
close $summary
delete_timing_netlist
project_close
if {$failed} {
    post_message -type error "Timing slack below the limit; see build/timing-corners.tsv"
    qexit -error
}
