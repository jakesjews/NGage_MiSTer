# quartus_sta -t report.tcl: worst paths per corner after the compile
project_open cpu_trial
create_timing_netlist
read_sdc
update_timing_netlist
foreach_in_collection op [get_available_operating_conditions] {
	set_operating_conditions $op
	update_timing_netlist
	set name [get_operating_conditions_info -display_name $op]
	set s [get_timing_paths -setup -npaths 1]
	foreach_in_collection p $s {
		puts "CORNER $name setup slack [get_path_info -slack $p]"
	}
	foreach_in_collection p [get_timing_paths -hold -npaths 1] {
		puts "HOLD $name hold slack [get_path_info -slack $p]"
	}
	report_timing -setup -npaths 30 -detail summary -file "output_files/paths_[string map {" " _} $name].txt"
	report_timing -setup -npaths 30 -detail full_path -file "output_files/detail_[string map {" " _} $name].txt"
    # Probe each endpoint family independently; the global top thirty can
    # otherwise be thirty aliases of one producer/consumer chain.
    foreach {family pattern} {
        execute {*u_execute|a*}
        decode_matches {*u_decode|o_forward_match*}
        decode_payload {*u_decode|d2*}
        decode_issue {*u_decode|issued*}
        dtlb {*u_data_cache|*u_zap_tlb_check|*}
        metadata {*u_data_cache|*u_zap_cache_tag_ram|*valid_q*}
        short_collision {*u_data_cache|*g_short.forward_write*}
        short_response {*u_data_cache|tr_cache_words*}
        locks {*u_data_cache|*u_zap_cache_fsm|*lock*}
        backend {*|g_arm9.u_arm9_core|w*}
        fetch {*u_fetch|*}
        rf {*u_zap_register_file|*}
    } {
        set endpoints [get_registers -nowarn $pattern]
        if {[get_collection_size $endpoints] > 0} {
            report_timing -setup -to $endpoints -npaths 1 -detail full_path -file "output_files/detail_family_${family}_[string map {" " _} $name].txt"
        }
    }
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
}
project_close
