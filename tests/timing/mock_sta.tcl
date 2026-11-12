# API substitute for exercising report orchestration, not a timing model.
set mode [lindex $argv 1]
set argv [lrange $argv 2 end]
set selected slow
proc project_open args {}
proc create_timing_netlist args {}
proc read_sdc args {}
proc update_timing_netlist args {}
proc delete_timing_netlist args {}
proc project_close args {}
proc get_clocks args {return sysclk}
proc post_message args {}
proc qexit args {exit 3}
proc foreach_in_collection {v xs script} {
    foreach x $xs {uplevel 1 [list set $v $x]; uplevel 1 $script}
}
proc report_timing {args} {
    set target [lindex $args [expr {[lsearch -exact $args -file]+1}]]
    set f [open $target w]; puts $f $args; close $f
}
proc report_ucp args {report_timing {*}$args}
proc report_clock_fmax_summary args {report_timing {*}$args}
proc get_available_operating_conditions {} {
    if {$::mode eq "empty"} {return {}}
    return {slow fast}
}
proc set_operating_conditions {corner} {set ::selected $corner}
proc get_operating_conditions_info args {return "Corner, \"$::selected\""}
proc get_timing_paths {args} {
    if {[lsearch -exact $args -from_clock] >= 0} {return uncertainty}
    if {[lsearch -exact $args -less_than_slack] >= 0} {
        if {[lindex $args [expr {[lsearch -exact $args -less_than_slack]+1}]] != 0} {error "missing negative filter"}
        if {[lindex $args [expr {[lsearch -exact $args -nworst]+1}]] != 1} {error "missing endpoint bound"}
        if {$::mode ne "fail" || $::selected eq "fast"} {return {}}
        set limit [lindex $args [expr {[lsearch -exact $args -npaths]+1}]]
        set result {}
        for {set n 1} {$n <= min(1200,$limit)} {incr n} {lappend result $n}
        return $result
    }
    return summary
}
proc get_path_info {option path} {
    switch -- $option {
        -required_points {return uncpoint}
        -slack {if {$::mode eq "fail" && $::selected eq "slow"} {return -1.453}; return 0.243}
        -data_delay {return 10.8}
        -num_logic_levels {return 11}
        -from_clock - -to_clock {return sysclk}
        -from {return {emu|upp_dma:dma|source[1],"x"}}
        -to {return {emu|upp_lcdif:lcd|destination[2]}}
    }
    error "unknown option $option"
}
proc get_node_info {option node} {return $node}
proc get_clock_info args {return sysclk}
proc get_point_info {option point} {
    if {$option eq "-type"} {return unc}
    if {$::mode eq "uncertainty"} {return -0.300}
    return -0.140
}
source $::env(NGAGE_REPORT_SCRIPT)
