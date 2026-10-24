project_open cpu_trial
create_timing_netlist
read_sdc
update_timing_netlist
foreach_in_collection op [get_available_operating_conditions] {
    set_operating_conditions $op
    update_timing_netlist
    set name [get_operating_conditions_info -display_name $op]
    # A's packed late-match field is [55:40]. Probe it separately from
    # operand capture so a removed completion cone cannot hide behind S/A.
    set late_endpoints [get_registers -nowarn {*__no_late_endpoint__*}]
    foreach_in_collection reg [get_registers -nowarn {*u_execute|a*}] {
        if {[regexp {\|a\[(4[0-9]|5[0-5])\]} [get_object_info -name $reg]]} {
            set late_endpoints [add_to_collection $late_endpoints [get_registers [get_object_info -name $reg]]]
        }
    }
    puts "LATE_MATCH_ENDPOINTS [get_collection_size $late_endpoints]"
    if {[get_collection_size $late_endpoints] > 0} {
        report_timing -setup -to $late_endpoints -npaths 1 -detail full_path -file "output_files/detail_family_execute_late_[string map {" " _} $name].txt"
    }
    foreach {family pattern} {
        dtlb_hit {*u_data_cache|*u_zap_tlb_check|o_hit_ok*}
        dtlb_fault {*u_data_cache|*u_zap_tlb_check|o_fsr*}
    } {
        report_timing -setup -to [get_registers $pattern] -npaths 1 -detail full_path -file "output_files/detail_family_${family}_[string map {" " _} $name].txt"
    }
}
project_close
