# quartus_sta -t detail.tcl: full detail of the worst setup paths (slow 100C)
project_open cpu_trial
create_timing_netlist
read_sdc
update_timing_netlist
report_timing -setup -npaths 4 -detail full_path -file output_files/detail.txt
project_close
