import csv
import os
from pathlib import Path
import subprocess
repo=Path(__file__).resolve().parents[2]
root=repo/'build/timing-script-tests'
root.mkdir(parents=True,exist_ok=True)
env=dict(os.environ, NGAGE_REPORT_SCRIPT=str(repo/'tools/report_timing.tcl'))
for mode,count,expected in [('fail',None,3),('pass',None,0),('uncertainty',None,3),('empty',None,1),('fail','17',3),('pass','0',1),('pass','10001',1),('pass','oops',1)]:
    work=root/(mode+'-'+str(count));work.mkdir(exist_ok=True)
    args=['tclsh',str(repo/'tests/timing/mock_sta.tcl'),'unused',mode]+([] if count is None else [count])
    run=subprocess.run(args,cwd=work,env=env,capture_output=True,text=True)
    assert run.returncode==expected,(mode,count,run.returncode,run.stderr)
    if mode in ('fail','pass') and expected != 1:
        rows=list(csv.DictReader((work/'build/timing/corner-01/failing-setup.csv').open()))
        assert len(rows)==(int(count or 1000) if mode=='fail' else 0)
        assert not list(csv.DictReader((work/'build/timing/corner-02/failing-setup.csv').open()))
        if rows:
            assert rows[0]['corner']=='Corner, "slow"'
            assert rows[0]['from_node']=='emu|upp_dma:dma|source[1],"x"'
            assert all(float(row['slack_ns'])<0 for row in rows)
        inv=list(csv.DictReader((work/'build/timing/corners.csv').open()))
        assert len(inv)==2 and inv[0]['corner']=='Corner, "slow"'
        for rpt in work.glob('build/timing/corner-*/failing-setup-full.rpt'):
            assert '-less_than_slack 0' in rpt.read_text() and '-show_routing' in rpt.read_text()
        paths=sorted(work.glob('build/timing/corner-*/failing-setup.csv'))
        subprocess.run(['python3',str(repo/'tools/summarize_timing.py'),*map(str,paths),'--output',str(work/'summary.md')],check=True,capture_output=True)
    print('PASS',mode,count)
print('Mock orchestration only: Quartus17 execution and routed timing remain unverified.')
