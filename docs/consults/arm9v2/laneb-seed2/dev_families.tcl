# quartus_sta -t dev_families.tcl: report.tcl's CPU endpoint families on the
# whole device (NGage), at the slow 100 C corner
project_open NGage
create_timing_netlist
read_sdc
update_timing_netlist
foreach_in_collection op [get_available_operating_conditions] {
    set name [get_operating_conditions_info -display_name $op]
    if {$name ne "Slow 1100mV 100C Model"} { continue }
    set_operating_conditions $op
    update_timing_netlist
    foreach {family pattern} {
        execute {*u_execute|a*}
        decode_matches {*u_decode|o_forward_match*}
        decode_grants {*u_decode|o_forward_grant*}
        decode_payload {*u_decode|d2*}
        decode_d1 {*u_decode|d1*}
        decode_issue {*u_decode|issued*}
        decode_redirect {*u_decode|redirect_ff*}
        dtlb {*u_data_cache|*u_zap_tlb_check|*}
        dtlb_hit {*u_data_cache|*u_zap_tlb_check|o_hit_ok*}
        dtlb_fault {*u_data_cache|*u_zap_tlb_check|o_fsr*}
        metadata {*u_data_cache|*u_zap_cache_tag_ram|*g_metadata*}
        metadata_descriptor {*u_data_cache|*u_zap_cache_tag_ram|meta_*}
        icache {*u_code_cache|*}
        serial_mask {*u_execute|interrupt_mask*}
        serial_release {*u_execute|o_serial_continue*}
        execute_flags {*u_execute|flags*}
        short_collision {*u_data_cache|*g_short_ram*addr_q*}
        short_response {*u_data_cache|tr_cache_words*}
        locks {*u_data_cache|*u_zap_cache_fsm|*lock*}
        backend {*|g_arm9.u_arm9_core|w*}
        backend_m {*|g_arm9.u_arm9_core|m*}
        backend_skid {*|g_arm9.u_arm9_core|skid*}
        tlb_metadata {*u_data_cache|*u_zap_tlb|*g_short.valid*}
        fetch {*u_fetch|*}
        rf {*u_zap_register_file|*}
    } {
        set endpoints [get_registers -nowarn $pattern]
        if {[get_collection_size $endpoints] > 0} {
            foreach_in_collection p [get_timing_paths -setup -to $endpoints -npaths 1] {
                puts "FAMILY $family slack [get_path_info -slack $p] from [get_node_info -name [get_path_info -from $p]] to [get_node_info -name [get_path_info -to $p]] data [get_path_info -data_delay $p]"
            }
            report_timing -setup -to $endpoints -npaths 1 -detail full_path -file "output_files/dev_family_${family}.txt"
        }
    }
}
project_close
