#!/usr/bin/env python3
"""Lint the BigMig_ch96 Quartus project without Quartus.

* reads the .qsf (and every .qip it pulls in, as Quartus would for
  Quartus 17: sys/pll_q17.qip) to get the Verilog/SystemVerilog files and
  the VERILOG_MACROs
* generates black-box stubs for the vendor primitives and the VHDL entities
  (altera_pll, altsyncram, cyclonev_* atoms, ascal, bram.vhd...): the ports
  and parameters are taken from the instances in the design itself
* runs Verilator --lint-only from the top level (ch96_top)

Usage: lint_tree.py <tree> <qsf> <workdir> [extra verilator args]"""
import os
import re
import subprocess
import sys

tree, qsf, work = os.path.abspath(sys.argv[1]), sys.argv[2], os.path.abspath(sys.argv[3])
extra = sys.argv[4:]
os.makedirs(work, exist_ok=True)

files, macros, vhdl, incdirs = [], [], [], []


def read_assignments(path, qip_dir):
    for raw in open(path, errors='replace'):
        line = raw.strip()
        if not line or line.startswith('#'):
            continue
        m = re.match(r'set_global_assignment\s+(?:-library\s+\S+\s+)?-name\s+(\S+)\s+(.*)$', line)
        if not m:
            m2 = re.match(r'source\s+(\S+)', line)
            if m2:
                read_assignments(os.path.join(tree, m2.group(1)), tree)
            continue
        kind, val = m.group(1), m.group(2).strip()
        # [file join $::quartus(qip_path) X]  /  [join [list $::quartus(qip_path) pll_q ... .qip] {}]
        val = re.sub(r'\s+-section_id.*$', '', val)
        if 'pll_q' in val and 'regexp' in val:
            val = os.path.join(qip_dir, 'pll_q17.qip')
        else:
            mj = re.match(r'\[file join \$::quartus\(qip_path\)\s+(.*?)\s*\]$', val)
            if mj:
                val = os.path.join(qip_dir, mj.group(1).strip().strip('"'))
            else:
                val = val.strip('"')
                if kind in ('QIP_FILE', 'VERILOG_FILE', 'SYSTEMVERILOG_FILE', 'VHDL_FILE', 'SEARCH_PATH') and not os.path.isabs(val):
                    val = os.path.join(tree, val)
        if kind == 'SEARCH_PATH':
            incdirs.append(os.path.normpath(val))
        elif kind == 'QIP_FILE':
            read_assignments(os.path.normpath(val), os.path.dirname(os.path.normpath(val)))
        elif kind in ('VERILOG_FILE', 'SYSTEMVERILOG_FILE'):
            p = os.path.normpath(val)
            if p not in files:
                files.append(p)
        elif kind == 'VHDL_FILE':
            vhdl.append(os.path.normpath(val))
        elif kind == 'VERILOG_MACRO':
            macros.append(val.strip('"'))


read_assignments(os.path.join(tree, qsf), tree)

missing = [f for f in files if not os.path.isfile(f)]
if missing:
    print("MISSING FILES:\n  " + "\n  ".join(missing))

# build_id.v is written by sys/build_id.tcl before every Quartus build
with open(os.path.join(work, 'build_id.v'), 'w') as f:
    f.write('`define BUILD_DATE "261109"\n')

# Quartus accepts an initialised unpacked *wire* array; Verilator wants a constant.
# Lint-only copies of the stock framework files that use it.
QUIRKS = {'yc_out.sv': ("wire signed [10:0] chroma_SIN_LUT[256] = '{", "localparam logic signed [10:0] chroma_SIN_LUT[256] = '{"),
          'mcp23009.sv': ("wire [15:0] init_data[12] = ", "localparam logic [15:0] init_data[12] = ")}
for k, f in enumerate(files):
    b = os.path.basename(f)
    if b in QUIRKS and os.path.isfile(f):
        t = open(f, errors='replace').read()
        a, r = QUIRKS[b]
        if a in t:
            nf = os.path.join(work, 'quirk_' + b)
            open(nf, 'w').write(t.replace(a, r))
            files[k] = nf

# ------------------------------------------------------------------ stubs
defined = set()
src_text = {}
for f in files:
    if not os.path.isfile(f):
        continue
    t = open(f, errors='replace').read()
    src_text[f] = t
    for m in re.finditer(r'^\s*module\s+(\w+)', t, re.M):
        defined.add(m.group(1))

BLACKBOX = re.compile(r'^(altera_pll|altsyncram|altera_std_synchronizer|altddio_out|altddio_in|cyclonev_\w+|ascal|pll_hdmi_adj|'
                      r'spram|spram_sz|dpram|dpram_dif|dpram_difclk|altera_pll_reconfig_top)$')

# instances: <mod> [#( ... )] <inst> ( ... );
inst_re = re.compile(r'\b(\w+)\s*(#\s*\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\))?\s*(\w+)\s*\(', re.S)
KNOWN_OUT = {
    'altera_pll': {'outclk', 'locked', 'fboutclk', 'phase_done', 'reconfig_from_pll', 'cascade_out', 'zdbfbclk', 'fbclk_out'},
    'altsyncram': {'q_a', 'q_b', 'eccstatus'},
    'altddio_out': {'dataout', 'oe_out'},
    'altddio_in': {'dataout_h', 'dataout_l'},
    'cyclonev_clkselect': {'outclk'},
    'cyclonev_lcell_comb': {'combout', 'cout', 'sumout', 'shareout'},
}
ports, params, outs, ins = {}, {}, {}, {}


def classify(expr, ptext):
    """'in' if the parent drives expr, 'out' if the black box must drive it."""
    e = expr.strip()
    if not e:
        return None
    ids = re.findall(r"[A-Za-z_]\w*", re.sub(r"\d+'[sS]?[bBoOdDhH][0-9a-fA-FxXzZ_]+", '', e))
    plain = re.fullmatch(r"\{?\s*[A-Za-z_][\w\[\]:\s,]*\}?", e) is not None
    if not plain or not ids:
        return 'in'
    for i in ids:
        if re.search(r'\binput\b[^;]*\b' + re.escape(i) + r'\b', ptext):
            return 'in'
        if re.search(r'\bassign\s+' + re.escape(i) + r'\b', ptext) or \
           re.search(r'(^|[;\s])' + re.escape(i) + r'(\s*\[[^\]]*\])?\s*<=', ptext, re.M) or \
           re.search(r'\b(wire|reg|logic)\b[^;]*\b' + re.escape(i) + r'\s*=\s*[^=]', ptext):
            return 'in'
    return 'out'


for f, t in src_text.items():
    t2 = re.sub(r'//[^\n]*', '', t)
    t2 = re.sub(r'/\*.*?\*/', '', t2, flags=re.S)
    inst_mod = {}
    for m in inst_re.finditer(t2):
        mod, inst = m.group(1), m.group(3)
        if mod in defined or not BLACKBOX.match(mod):
            continue
        inst_mod[inst] = mod
        i, depth = m.end(), 1
        while depth and i < len(t2):
            depth += {'(': 1, ')': -1}.get(t2[i], 0)
            i += 1
        body = t2[m.end():i - 1]
        ports.setdefault(mod, set())
        for pm in re.finditer(r'\.(\w+)\s*\(', body):
            pname = pm.group(1)
            j, d = pm.end(), 1
            while d and j < len(body):
                d += {'(': 1, ')': -1}.get(body[j], 0)
                j += 1
            expr = body[pm.end():j - 1]
            ports[mod].add(pname)
            if pname in KNOWN_OUT.get(mod, set()):
                outs.setdefault(mod, set()).add(pname)
                continue
            c = classify(expr, t2)
            if c == 'in':
                ins.setdefault(mod, set()).add(pname)
            elif c == 'out':
                outs.setdefault(mod, set()).add(pname)
        if m.group(2):
            params.setdefault(mod, set()).update(re.findall(r'\.(\w+)\s*\(', m.group(2)))
        npos = len([x for x in re.split(r',', body) if x.strip() and not x.strip().startswith('.')])
        if npos and not ports[mod]:
            ports[mod] = {f'p{k}' for k in range(npos)}
        if m.group(2) and not params.get(mod):
            npar = len([x for x in m.group(2)[1:].strip()[1:-1].split(',') if x.strip()])
            params[mod] = {f'P{k}' for k in range(npar)}
    for dm in re.finditer(r'\bdefparam\b(.*?);', t2, re.S):
        for im in re.finditer(r'(\w+)\s*\.\s*(\w+)\s*=', dm.group(1)):
            if im.group(1) in inst_mod:
                params.setdefault(inst_mod[im.group(1)], set()).add(im.group(2))

with open(os.path.join(work, 'stubs.sv'), 'w') as f:
    f.write('// generated black boxes for the lint run\n/* verilator lint_off DECLFILENAME */\n'
            '/* verilator lint_off UNUSEDSIGNAL */\n/* verilator lint_off UNDRIVEN */\n')
    for mod in sorted(ports):
        pl = sorted(ports[mod])
        f.write(f'module {mod}\n')
        if params.get(mod):
            f.write('  #(' + ', '.join(f'parameter {p} = 0' for p in sorted(params[mod])) + ')\n')
        decl = []
        for p_ in pl:
            if p_ in outs.get(mod, set()) and p_ not in ins.get(mod, set()):
                decl.append(f'output wire [1023:0] {p_}')
            else:
                decl.append(f'input wire [1023:0] {p_}')
        f.write('  (' + ', '.join(decl) + ');\n')
        for p_ in pl:
            if p_ in outs.get(mod, set()) and p_ not in ins.get(mod, set()):
                f.write(f'  assign {p_} = 1024\'d0;\n')
        f.write('endmodule\n')
print("black boxes:", ', '.join(sorted(ports)))

cmd = ['verilator', '--lint-only', '--no-timing', '-Wno-fatal', '-Wno-WIDTH', '-Wno-PINMISSING', '-Wno-IMPLICIT',
       '-Wno-UNUSED', '-Wno-UNDRIVEN', '-Wno-CASEINCOMPLETE', '-Wno-DECLFILENAME', '-Wno-PINCONNECTEMPTY',
       '-Wno-SYNCASYNCNET', '-Wno-MULTIDRIVEN', '-Wno-TIMESCALEMOD', '-Wno-INITIALDLY', '-Wno-COMBDLY',
       '-Wno-BLKANDNBLK', '-Wno-LATCH', '-Wno-UNOPTFLAT', '-Wno-CASEX', '-Wno-CASEOVERLAP', '-Wno-ASCRANGE',
       '-Wno-SELRANGE', '-Wno-LITENDIAN', '-Wno-BLKSEQ', '-Wno-PINNOCONNECT', '-Wno-GENUNNAMED',
       '-Wno-VARHIDDEN', '-Wno-MULTITOP', '-Wno-ENUMVALUE', '-Wno-REDEFMACRO', '-Wno-ALWCOMBORDER',
       '-Wno-UNPACKED', '-Wno-INCABSPATH', '-Wno-SIDEEFFECT', '-Wno-PROCASSWIRE',
       '-Wno-ASSIGNIN',   # stock sys_top: an input pin inside the emu ADC_BUS inout concatenation
       '--top-module', 'ch96_top', f'-I{work}', f'-I{tree}', f'-I{tree}/rtl', f'-I{tree}/sys']
cmd += [f'-I{d}' for d in incdirs]
cmd += [f'+define+{m}' for m in macros]
cmd += extra
cmd += [os.path.join(work, 'stubs.sv')] + [f for f in files if os.path.isfile(f)]
print("macros:", ' '.join(macros))
print("files :", len(files), "(+ VHDL left to Quartus:", ', '.join(os.path.basename(v) for v in vhdl) + ")")
r = subprocess.run(cmd, cwd=tree, capture_output=True, text=True)
open(os.path.join(work, 'verilator.log'), 'w').write(r.stdout + r.stderr)
print("verilator exit:", r.returncode)
errs = [l for l in (r.stdout + r.stderr).splitlines() if l.startswith('%Error')]
print("errors:", len(errs))
for l in errs[:60]:
    print(" ", l)
