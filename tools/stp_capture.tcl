# Headless SignalTap acquisition on the server's JTAG server.
#   docker exec ngage-jtag /opt/intelFPGA_lite/quartus/bin/quartus_stp -t /project/tools/stp_capture.tcl STP INSTANCE TIMEOUT_S [HARDWARE_PATTERN]
# Arms INSTANCE's trigger (the names tools/gen_stp.py wrote: "signal_set: X" and
# "trigger: X"), waits up to TIMEOUT_S seconds for it, and saves the captured
# data into STP as data log "log_1"; the caller decodes the XML.
package require ::quartus::stp
lassign $quartus(args) stp inst timeout hwpat
if {$hwpat eq ""} { set hwpat "*" }
set hw ""
foreach h [get_hardware_names] { if {[string match $hwpat $h]} { set hw $h; break } }
if {$hw eq ""} { puts "no JTAG hardware matching $hwpat: [get_hardware_names]"; exit 1 }
set dev ""
foreach d [get_device_names -hardware_name $hw] { if {[string match "*5CSEBA6*" $d] || [string match "*5CSEMA6*" $d]} { set dev $d; break } }
if {$dev eq ""} { puts "no 5CSEBA6 on $hw: [get_device_names -hardware_name $hw]"; exit 1 }
puts "hardware: $hw  device: $dev"
open_session -name $stp
set rc [catch {run -hardware $hw -device $dev -instance $inst -signal_set "signal_set: $inst" -trigger "trigger: $inst" -data_log log_1 -timeout $timeout} msg]
puts "run: $msg"
save_session
close_session
exit $rc
