import re,sys
def load(p):
    d={}
    for l in open(p):
        m=re.match(r'(FAMILY|BPATH) (\S+) slack (-?[\d.]+) from (\S+) to (\S+)',l)
        if m: d[m.group(2)]=(float(m.group(3)),m.group(4).split('|')[-1],m.group(5).split('|')[-1])
    return d
cols=[(a.split('=')[0],load(a.split('=')[1])) for a in sys.argv[1:]]
keys=sorted(set().union(*[set(d) for _,d in cols]), key=lambda k: cols[-1][1].get(k,(99,))[0])
print('family'.ljust(20)+''.join(n.rjust(9) for n,_ in cols))
for k in keys:
    last=cols[-1][1].get(k)
    print(k.ljust(20)+''.join((f"{d[k][0]:9.3f}" if k in d else '      -  ') for _,d in cols)+(f"   {last[1]} -> {last[2]}" if last else ''))
