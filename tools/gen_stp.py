#!/usr/bin/env python3
"""Generate a SignalTap II file (.stp) for Quartus 17 from a small JSON spec,
so a probe set and trigger can be built headlessly on the server.

Spec (JSON):
  {"clock": "emu:emu|clk_sys", "depth": 2048, "ram": "M10K",
   "instances": [
     {"name": "auto_signaltap_0", "position": "pre",
      "nodes": [["emu:emu|tr_d_va", 32], ["emu:emu|tr_d_done", 1], ...],
      "trigger": {"emu:emu|tr_d_done": "1", "emu:emu|tr_d_va": "0x5961d820"}}]}
A node is [name, width]; width 1 is a scalar wire "name", wider ones are the
bits "name[i]". The trigger maps a node name to "1"/"0"/"R"/"F" for scalars or
a hex value for buses (every bit then high/low); nodes not listed are don't
care. Usage: gen_stp.py SPEC.json OUT.stp
"""
import json, sys
from xml.sax.saxutils import quoteattr as q

spec = json.load(open(sys.argv[1]))
clock = spec["clock"]; depth = int(spec.get("depth", 2048)); ram = spec.get("ram", "AUTO")
LEVEL = {"1": "high", "0": "low", "R": "rising_edge", "F": "falling_edge", "X": "dont_care"}

def bits(name, width):
    return [name] if width == 1 else [f"{name}[{i}]" for i in range(width)]

out = ['<session jtag_chain="" jtag_device="" sof_file="">', '  <display_tree gui_logging_enabled="0">']
for k, inst in enumerate(spec["instances"]):
    out.append(f'    <display_branch instance={q(inst["name"])} signal_set="USE_GLOBAL_TEMP" trigger="USE_GLOBAL_TEMP"/>')
out += ['  </display_tree>', '  <mnemonics/>']
for k, inst in enumerate(spec["instances"]):
    name = inst["name"]; nodes = inst["nodes"]; trig = inst.get("trigger", {})
    out.append(f'  <instance enabled="true" entity_name="sld_signaltap" is_auto_node="yes" is_expanded="true" name={q(name)} source_file="sld_signaltap.vhd">')
    out.append(f'    <node_ip_info instance_id="{k}" mfg_id="110" node_id="0" version="6"/>')
    out.append(f'    <signal_set global_temp="1" name="signal_set: {name}">')
    out.append(f'      <clock name={q(clock)} polarity="posedge" tap_mode="classic"/>')
    out.append(f'      <config pipeline_level="0" ram_type="{ram}" reserved_data_nodes="0" reserved_storage_qualifier_nodes="0" reserved_trigger_nodes="0" sample_depth="{depth}" trigger_in_enable="no" trigger_out_enable="no"/>')
    out.append('      <top_entity/>')
    wires = [w for n, wd in nodes for w in bits(n, wd)]
    for sec in ("trigger_input_vec", "data_input_vec", "storage_qualifier_input_vec"):
        out.append(f'      <signal_vec><{sec}>' if sec == "trigger_input_vec" else f'        <{sec}>')
        for w in wires:
            out.append(f'          <wire name={q(w)} tap_mode="classic" type="combinatorial"/>')
        out.append(f'        </{sec}>')
    out.append('      </signal_vec>')
    out.append('      <presentation>')
    out.append('        <unified_setup_data_view>')
    idx = 0
    for n, wd in nodes:
        t = trig.get(n)
        if wd == 1:
            lvl = LEVEL.get(t or "X", "dont_care")
            out.append(f'          <node data_index="{idx}" duplicate_name_allowed="false" is_data_input="true" is_node_valid="true" is_selected="false" is_storage_input="true" is_trigger_input="true" level-0="{lvl}" name={q(n)} pwr_is_transition_enabled="false" pwr_level-0="dont_care" pwr_storage-0="dont_care" storage-0="dont_care" storage_index="{idx}" tap_mode="classic" trigger_index="{idx}" type="combinatorial"/>')
            idx += 1
        else:
            val = int(t, 16) if t else None
            out.append(f'          <bus is_selected="false" level-0="alt_or" name={q(n + f"[{wd-1}..0]")} order="msb_to_lsb" pwr_level-0="alt_or" pwr_storage-0="alt_or" storage-0="alt_or" type="combinatorial">')
            for i in reversed(range(wd)):
                lvl = "dont_care" if val is None else ("high" if (val >> i) & 1 else "low")
                out.append(f'            <node data_index="{idx+i}" duplicate_name_allowed="false" is_data_input="true" is_node_valid="true" is_selected="false" is_storage_input="true" is_trigger_input="true" level-0="{lvl}" name={q(f"{n}[{i}]")} pwr_is_transition_enabled="false" pwr_level-0="dont_care" pwr_storage-0="dont_care" storage-0="dont_care" storage_index="{idx+i}" tap_mode="classic" trigger_index="{idx+i}" type="combinatorial"/>')
            out.append('          </bus>')
            idx += wd
    out.append('        </unified_setup_data_view>')
    out.append('        <trigger_in_editor/>')
    out.append('        <trigger_out_editor/>')
    out.append('      </presentation>')
    pos = inst.get("position", "pre")
    out.append(f'      <trigger attribute_mem_mode="false" gap_record="true" global_temp="1" name="trigger: {name}" position="{pos}" power_up_trigger_mode="false" record_data_gap="true" segment_size="{depth}" storage_mode="continuous" storage_qualifier_disabled="yes" trigger_type="circular">')
    out.append(f'        <power_up_trigger position="{pos}" storage_qualifier_disabled="yes"/>')
    out.append('        <events use_custom_flow_control="no">')
    out.append('          <level enabled="yes" name="condition1" type="basic">')
    out.append('            <power_up enabled="yes">')
    out.append('            </power_up>')
    out.append('            <op_node/>')
    out.append('          </level>')
    out.append('        </events>')
    out.append('      </trigger>')
    out.append('    </signal_set>')
    out.append('  </instance>')
out.append('  <global_info>')
out.append('    <single attribute="active instance" value="0"/>')
out.append('  </global_info>')
out.append('</session>')
open(sys.argv[2], "w").write("\n".join(out) + "\n")
print(f"wrote {sys.argv[2]}: {sum(1 for i in spec['instances'] for n,w in i['nodes'] for _ in range(w))} bits in {len(spec['instances'])} instance(s)")
