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
foreach_in_collection corner [get_available_operating_conditions] {
    set_operating_conditions $corner
    update_timing_netlist
    set name [get_operating_conditions_info -display_name $corner]
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
delete_timing_netlist
project_close
if {$failed} {
    post_message -type error "Negative timing slack; see build/timing-corners.tsv"
    qexit -error
}
