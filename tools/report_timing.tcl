# Run after fitting: quartus_sta -t tools/report_timing.tcl [path_count]
# Up to path_count negative setup endpoints PER corner, worst first.
# No clock, constraint, fit setting or sign-off threshold changes.
set path_count 1000
if {[llength $argv] > 1} {error "Usage: report_timing.tcl \[path_count\]"}
if {[llength $argv] == 1} {set path_count [lindex $argv 0]}
if {![string is integer -strict $path_count] || $path_count < 1 || $path_count > 10000} {
    error "Path count must be an integer from 1 to 10000"
}

proc csv_cell {value} {
    return "\"[string map [list \" \"\"] $value]\""
}
proc path_clock {path option} {
    set id [get_path_info $option $path]
    if {$id eq ""} {return ""}
    return [get_clock_info -name $id]
}
proc export_failing_setup {directory count corner} {
    # One worst path per endpoint avoids filling the sample with variants of
    # one sink. Zero paths is valid at a passing corner; keep a CSV header.
    report_timing -setup -less_than_slack 0 -npaths $count -nworst 1 \
        -detail full_path -show_routing -file $directory/failing-setup-full.rpt
    set paths [get_timing_paths -setup -less_than_slack 0 -npaths $count \
        -nworst 1 -detail full_path]
    set f [open $directory/failing-setup.csv w]
    puts $f "rank,corner,slack_ns,data_delay_ns,logic_levels,from_clock,to_clock,from_node,to_node"
    set rank 0
    foreach_in_collection path $paths {
        incr rank
        set cells {}
        foreach field [list $rank $corner [get_path_info -slack $path] \
            [get_path_info -data_delay $path] [get_path_info -num_logic_levels $path] \
            [path_clock $path -from_clock] [path_clock $path -to_clock] \
            [get_node_info -name [get_path_info -from $path]] \
            [get_node_info -name [get_path_info -to $path]]] {
            lappend cells [csv_cell $field]
        }
        puts $f [join $cells ,]
    }
    close $f
    post_message -type info "$corner: exported $rank failing setup endpoints (limit $count)"
    return $rank
}
project_open NGage
create_timing_netlist
read_sdc
update_timing_netlist
file mkdir build
report_timing -setup -less_than_slack 0 -npaths $path_count -nworst 1 -detail full_path -show_routing -file build/critical-paths.rpt
report_timing -hold -npaths 10 -detail full_path -file build/hold-paths.rpt
report_ucp -file build/unconstrained-paths.rpt
set summary [open build/timing-corners.tsv w]
puts $summary "corner\tcheck\tworst_slack_ns"
set failed 0
set corner_index 0
file mkdir build/timing
set inventory [open build/timing/corners.csv w]
puts $inventory "directory,corner,exported_failing_endpoints,limit"
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
    incr corner_index
    # Numeric paths avoid spaces/punctuation in operating-condition names.
    set directory [format "build/timing/corner-%02d" $corner_index]
    file mkdir $directory
    set exported [export_failing_setup $directory $path_count $name]
    puts $inventory "[csv_cell $directory],[csv_cell $name],$exported,$path_count"
    report_clock_fmax_summary -file $directory/fmax.rpt
    report_timing -hold -npaths 100 -nworst 1 -detail full_path -show_routing \
        -file $directory/hold-full.rpt
    foreach check {setup hold recovery removal} {
        foreach_in_collection path [get_timing_paths -$check -npaths 1] {
            set slack [get_path_info -slack $path]
            puts $summary "$name\t$check\t$slack"
            post_message -type info "$name ${check}: $slack ns"
            if {$slack < 0} { set failed 1 }
        }
    }
}
close $summary
close $inventory
if {$corner_index == 0} {error "No operating conditions found; refusing an unchecked timing result"}
delete_timing_netlist
project_close
if {$failed} {
    post_message -type error "Negative timing slack; see build/timing-corners.tsv"
    qexit -error
}
