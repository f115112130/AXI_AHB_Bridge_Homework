#!/usr/bin/env python3
"""
Cycle-accurate behavioral model that mirrors rtl/ahb_wrappers.v and rtl/axi_wrappers.v.
Outputs: ahb.vcd / axi.vcd  (open with GTKWave)  and PNG waveforms.
Each loop iteration = one clock cycle; all outputs are Moore (computed from current regs),
then every module's next state is computed from those outputs (same as non-blocking RTL).
"""
import os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Polygon

OUT = os.path.dirname(os.path.abspath(__file__))

# ----------------------------------------------------------------------------
# AHB
# ----------------------------------------------------------------------------
class AhbM:
    N = ["M_IDLE", "M_ADDR", "M_BURST", "M_LAST", "M_DONE", "M_ERR"]
    def __init__(s):
        s.st = 0; s.addr = 0; s.ca = 0; s.cd = 0; s.ln = 0; s.wr = 0; s.hsize = 0
        s.rbuf = [0] * 8
    def out(s, wdata):
        return dict(htrans={1: 2, 2: 3}.get(s.st, 0), haddr=s.addr, hwrite=s.wr,
                    hwdata=(wdata[s.cd] if s.st in (2, 3) else 0),
                    irq=int(s.st == 4), err=int(s.st == 5))
    def step(s, start, wr, base, ln, hsize, hready, hresp, hrdata):
        st = s.st; inc = 1 << s.hsize
        if st == 0:
            if start:
                s.ln, s.wr, s.hsize, s.addr, s.ca, s.cd, s.st = ln, wr, hsize, base, 0, 0, 1
        elif st == 1:
            if hready:
                s.addr += inc; s.ca += 1; s.st = 3 if s.ln == 1 else 2
        elif st in (2, 3):
            if (not hready) and hresp:
                s.st = 5
            elif hready:
                if not s.wr: s.rbuf[s.cd] = hrdata
                s.cd += 1
                if st == 2:
                    if s.ca == s.ln - 1: s.st = 3
                    s.addr += inc; s.ca += 1
                else:
                    s.st = 4
        elif st == 4:
            s.st = 0
        elif st == 5:
            if hready: s.st = 0

class AhbS:
    RN = ["R_IDLE", "R_WAIT", "R_DATA"]; WN = ["W_IDLE", "W_DATA"]
    def __init__(s): s.rs = 0; s.ws = 0; s.radr = 0; s.wadr = 0
    def out(s, int_rx, int_tx, ip_dat):
        rd_hro = int(s.rs != 1)
        wr_hro = int_tx if s.ws == 1 else 1
        wr_stb = int(s.ws == 1 and int_tx)
        return dict(hro=rd_hro & wr_hro, rd_stb=int(s.rs == 2), wr_stb=wr_stb,
                    hrdata=ip_dat if s.rs == 2 else 0,
                    adr=s.wadr if s.ws == 1 else s.radr)
    def step(s, hsel, hready, haddr, htrans, hwrite, int_rx):
        req = hsel and hready and (htrans >> 1) & 1
        rd_req = req and not hwrite; wr_req = req and hwrite
        if s.rs == 0:
            if rd_req: s.radr = haddr & 3; s.rs = 1
        elif s.rs == 1:
            if int_rx: s.rs = 2
        elif s.rs == 2:
            if hready:
                if rd_req: s.radr = haddr & 3; s.rs = 1
                else: s.rs = 0
        if s.ws == 0:
            if wr_req: s.wadr = haddr & 3; s.ws = 1
        else:
            if hready:
                if wr_req: s.wadr = haddr & 3
                else: s.ws = 0

class IpAhb:
    def __init__(s): s.mem = [0xA0, 0xA1, 0xA2, 0xA3]; s.rx = 3; s.tx = 0
    def out(s, adr): return dict(int_rx=int(s.rx == 0), int_tx=int(s.tx == 0), dat=s.mem[adr])
    def step(s, stb, we, adr, dat):
        rx, tx = s.rx, s.tx
        if stb and not we: s.rx = 1
        elif rx: s.rx = rx - 1
        if stb and we: s.mem[adr] = dat & 0xFF; s.tx = 1
        elif tx: s.tx = tx - 1

def run_ahb():
    m, s, ip = AhbM(), AhbS(), IpAhb()
    wdata = [0x11, 0x22, 0x33, 0x44, 0, 0, 0, 0]
    log = []; phase = 0; t_start = 3; t_rd = None; t_end = None; mark = {}
    for cyc in range(80):
        rst = cyc < 2
        start = int((cyc == t_start and phase == 0) or (t_rd is not None and cyc == t_rd))
        wr = 1 if phase == 0 else 0
        # ---- Moore outputs from current registers
        mo = m.out(wdata)
        adr = s.wadr if s.ws == 1 else s.radr
        ipo = ip.out(adr)
        so = s.out(ipo["int_rx"], ipo["int_tx"], ipo["dat"])
        hready, hresp = so["hro"], 0
        log.append(dict(
            hclk=1, hresetn=int(not rst), start=start, mst=m.st, htrans=mo["htrans"], haddr=mo["haddr"],
            hwrite=mo["hwrite"], hwdata=mo["hwdata"], hrdata=so["hrdata"], hready=hready, hresp=hresp,
            irq=mo["irq"], rs=s.rs, ws=s.ws, stb=so["rd_stb"] | so["wr_stb"], we=so["wr_stb"],
            adr=so["adr"], int_rx=ipo["int_rx"], int_tx=ipo["int_tx"]))
        if rst:
            continue
        # ---- next state (all computed from pre-edge values)
        stb, we = so["rd_stb"] | so["wr_stb"], so["wr_stb"]
        m.step(start, wr, 0x10000000, 4, 0, hready, hresp, so["hrdata"])
        s.step(1, hready, mo["haddr"], mo["htrans"], mo["hwrite"], ipo["int_rx"])
        ip.step(stb, we, so["adr"], wdata_byte(mo["hwdata"]))
        if mo["irq"] and phase == 0:
            phase = 1; t_rd = cyc + 3; mark["w_end"] = cyc
        elif mo["irq"] and phase == 1:
            t_end = cyc; mark["r_end"] = cyc
        if t_end is not None and cyc >= t_end + 3:
            break
    mark["t_rd"] = t_rd
    return log, mark, m.rbuf, ip.mem

def wdata_byte(v): return v & 0xFF

# ----------------------------------------------------------------------------
# AXI
# ----------------------------------------------------------------------------
class AxiMR:
    N = ["M_IDLE", "M_AR", "M_R", "M_DONE", "M_ERR"]
    def __init__(s): s.st = 0; s.addr = 0; s.ln = 0
    def step(s, start, addr_i, len_i, arready, rvalid, rresp, rlast):
        if s.st == 0:
            if start: s.addr, s.ln, s.st = addr_i, len_i, 1
        elif s.st == 1:
            if arready: s.st = 2
        elif s.st == 2:
            if rvalid:
                if rresp: s.st = 4
                elif rlast: s.st = 3
                else: s.addr += 4
        else: s.st = 0

class AxiSR:
    N = ["R_IDLE", "R_WAIT", "R_ACCESS", "R_DATA"]
    def __init__(s): s.st = 0; s.id = 0; s.adr = 0; s.data = 0; s.rem = 0; s.last = 0
    def step(s, arvalid, arid, araddr, arlen, int_rx, ack, ip_dat, rready):
        if s.st == 0:
            if arvalid: s.id, s.adr, s.rem, s.st = arid, araddr, arlen, 1
        elif s.st == 1:
            if int_rx: s.st = 2
        elif s.st == 2:
            if ack: s.data = ip_dat; s.last = int(s.rem == 0); s.st = 3
        else:
            if rready:
                if s.last: s.st = 0
                else: s.rem -= 1; s.adr += 4; s.st = 1

class AxiMW:
    N = ["M_IDLE", "M_AW", "M_W", "M_B", "M_DONE", "M_ERR"]
    def __init__(s): s.st = 0; s.addr = 0; s.seed = 0; s.tot = 0; s.ln = 0; s.beat = 0; s.nb = 0
    def wlast(s): return int(s.beat == s.ln - 1)
    def wdata(s): return (s.seed + s.tot) & 0xFFFFFFFF
    def step(s, start, addr_i, len_i, nb_i, seed, awready, wready, bvalid, bresp):
        if s.st == 0:
            if start: s.addr, s.ln, s.nb, s.seed, s.tot, s.st = addr_i, len_i, nb_i, seed, 0, 1
        elif s.st == 1:
            if awready: s.beat = 0; s.st = 2
        elif s.st == 2:
            if wready:
                last = s.wlast(); s.tot += 1
                if last: s.st = 3
                else: s.beat += 1
        elif s.st == 3:
            if bvalid:
                if bresp: s.st = 5
                elif s.nb > 1: s.nb -= 1; s.addr += s.ln * 4; s.st = 1
                else: s.st = 4
        else: s.st = 0

class AxiSW:
    N = ["W_IDLE", "W_DATA", "W_ACCESS", "W_RESP"]
    def __init__(s): s.st = 0; s.id = 0; s.adr = 0; s.data = 0; s.last = 0
    def step(s, awvalid, awid, awaddr, wvalid, wready, wdata, wlast, ack, bready):
        if s.st == 0:
            if awvalid: s.id, s.adr, s.st = awid, awaddr, 1
        elif s.st == 1:
            if wvalid and wready: s.data, s.last, s.st = wdata, wlast, 2
        elif s.st == 2:
            if ack:
                if s.last: s.st = 3
                else: s.adr += 4; s.st = 1
        else:
            if bready: s.st = 0

class IpAxi:
    def __init__(s): s.mem = [0xD0000000 + k for k in range(16)]; s.ack = 0; s.rx = 3; s.tx = 0
    def out(s, adr): return dict(ack=s.ack, int_rx=int(s.rx == 0), int_tx=int(s.tx == 0), dout=s.mem[(adr >> 2) & 15])
    def step(s, stb, we, adr, din):
        ack, rx, tx = s.ack, s.rx, s.tx
        s.ack = int(stb and not ack)
        if stb and not we and ack: s.rx = 2
        elif rx: s.rx = rx - 1
        if stb and we and ack: s.mem[(adr >> 2) & 15] = din; s.tx = 2
        elif tx: s.tx = tx - 1

# ----------------------------------------------------------------------------
# AXI run (IP write data = data latched by the slave wrapper in W_DATA)
# ----------------------------------------------------------------------------
def run_axi():
    mw, sw, mr, sr, ip = AxiMW(), AxiSW(), AxiMR(), AxiSR(), IpAxi()
    log = []; r_start_c = None; end_c = None; mark = {}; rd_got = []
    w_start_c = 3
    for cyc in range(160):
        rst = cyc < 2
        w_start = int(cyc == w_start_c)
        r_start = int(r_start_c is not None and cyc == r_start_c)
        awvalid = int(mw.st == 1); wvalid = int(mw.st == 2); bready = int(mw.st == 3)
        awready = int(sw.st == 0); bvalid = int(sw.st == 3)
        arvalid = int(mr.st == 1); rready = int(mr.st == 2)
        arready = int(sr.st == 0); rvalid = int(sr.st == 3)
        rd_stb = int(sr.st == 2); wr_stb = int(sw.st == 2)
        adr = sw.adr if wr_stb else sr.adr
        ipo = ip.out(adr & 0xFFFF)
        wready = int(sw.st == 1 and ipo["int_tx"])
        rd_vld = int(mr.st == 2 and rvalid)
        wlast = mw.wlast() if wvalid else 0
        row = dict(
            aclk=1, aresetn=int(not rst),
            mw=mw.st, awvalid=awvalid, awready=awready, awaddr=mw.addr, awlen=(mw.ln - 1) & 0xFF,
            wvalid=wvalid, wready=wready, wdata=mw.wdata(), wlast=wlast,
            bvalid=bvalid, bready=bready, sw=sw.st,
            mr=mr.st, arvalid=arvalid, arready=arready, araddr=mr.addr, arlen=(mr.ln - 1) & 0xFF,
            rvalid=rvalid, rready=rready, rdata=sr.data, rlast=(sr.last if rvalid else 0), sr=sr.st,
            stb=rd_stb | wr_stb, we=wr_stb, ack=ipo["ack"], int_rx=ipo["int_rx"], int_tx=ipo["int_tx"],
            done_w=int(mw.st == 4), done_r=int(mr.st == 3))
        log.append(row)
        if rst: continue
        if rd_vld: rd_got.append(sr.data)
        # next state (all use pre-edge values)
        sw_next_in = dict(awvalid=awvalid, awid=1, awaddr=mw.addr, wvalid=wvalid, wready=wready,
                          wdata=mw.wdata(), wlast=wlast, ack=ipo["ack"], bready=bready)
        sr_next_in = dict(arvalid=arvalid, arid=1, araddr=mr.addr, arlen=(mr.ln - 1) & 0xFF,
                          int_rx=ipo["int_rx"], ack=ipo["ack"], ip_dat=ipo["dout"], rready=rready)
        mw.step(w_start, 0x40000000, 2, 2, 0xA5A50000, awready, wready, bvalid, 0)
        mr.step(r_start, 0x40000000, 4, arready, rvalid, 0, sr.last)
        ip_din = sw.data
        sw.step(**sw_next_in)
        sr.step(**sr_next_in)
        ip.step(rd_stb | wr_stb, wr_stb, adr & 0xFFFF, ip_din)
        if row["done_w"] and "w_end" not in mark:
            mark["w_end"] = cyc; r_start_c = cyc + 3
        if row["done_r"]:
            mark["r_end"] = cyc; end_c = cyc
        if end_c is not None and cyc >= end_c + 3: break
    mark["r_start"] = r_start_c
    return log, mark, rd_got

# ----------------------------------------------------------------------------
# VCD writer
# ----------------------------------------------------------------------------
def write_vcd(path, log, widths, scope):
    ids = {}
    chars = [chr(c) for c in range(33, 127)]
    with open(path, "w") as f:
        f.write("$timescale 1ns $end\n$scope module %s $end\n" % scope)
        for i, (k, w) in enumerate(widths.items()):
            ids[k] = chars[i] if i < len(chars) else chars[i // 90] + chars[i % 90]
            f.write("$var wire %d %s %s $end\n" % (w, ids[k], k))
        f.write("$upscope $end\n$enddefinitions $end\n")
        prev = {}
        for c, row in enumerate(log):
            f.write("#%d\n" % (c * 10))
            f.write("1%s\n" % ids[list(widths)[0]])        # clock rises at the cycle start
            for k, w in widths.items():
                if k == list(widths)[0]: continue
                v = row[k]
                if prev.get(k) != v:
                    f.write(("%d%s\n" % (v, ids[k])) if w == 1 else ("b%s %s\n" % (format(v, "b"), ids[k])))
                    prev[k] = v
            f.write("#%d\n0%s\n" % (c * 10 + 5, ids[list(widths)[0]]))

# ----------------------------------------------------------------------------
# Waveform plotter
# ----------------------------------------------------------------------------
COL = dict(idle="#f5f5f5", active="#dae8fc", wait="#fff2cc", done="#d5e8d4", err="#f8cecc", bus="#ffffff")

def draw(rows, c0, c1, title, fn, cmap):
    n = len(rows); cw = 0.55
    fig, ax = plt.subplots(figsize=((c1 - c0) * cw + 2.4, n * 0.42 + 0.9), dpi=110)
    for i, (label, kind, vals, *extra) in enumerate(rows):
        y = n - 1 - i
        ax.text(c0 - 0.15, y + 0.4, label, ha="right", va="center", fontsize=7.5, family="monospace")
        v = vals[c0:c1]
        if kind == "clk":
            for c in range(len(v)):
                x = c0 + c
                ax.plot([x, x, x + .5, x + .5, x + 1], [y + .1, y + .7, y + .7, y + .1, y + .1], "k", lw=0.8)
        elif kind == "bit":
            xs = list(range(c0, c0 + len(v) + 1)); ys = [y + (.7 if b else .1) for b in v] + [y + (.7 if v[-1] else .1)]
            ax.step(xs, ys, where="post", color="#1f4e9c", lw=1.2)
            ax.plot([c0, c0 + len(v)], [y + .1] * 2, color="#dddddd", lw=0.4, zorder=0)
        else:
            fmt = extra[0] if extra else (lambda q: "%X" % q)
            s = 0
            while s < len(v):
                e = s
                while e + 1 < len(v) and v[e + 1] == v[s]: e += 1
                x0, x1 = c0 + s, c0 + e + 1
                name = fmt(v[s])
                fc = cmap.get(name, COL["bus"]) if kind == "state" else COL["bus"]
                ax.add_patch(Polygon([(x0 + .05, y + .4), (x0 + .15, y + .7), (x1 - .15, y + .7), (x1 - .05, y + .4),
                                      (x1 - .15, y + .1), (x0 + .15, y + .1)], closed=True, fc=fc, ec="k", lw=0.7))
                ax.text((x0 + x1) / 2, y + .4, name, ha="center", va="center", fontsize=6.3 if kind == "state" else 6.5)
                s = e + 1
    for c in range(c0, c1 + 1):
        ax.axvline(c, color="#eeeeee", lw=0.5, zorder=0)
    ax.set_xlim(c0 - 0.1, c1); ax.set_ylim(-0.1, n)
    ax.set_xticks([c + .5 for c in range(c0, c1)]); ax.set_xticklabels([str(c) for c in range(c0, c1)], fontsize=6)
    ax.set_yticks([]); ax.set_xlabel("clock cycle", fontsize=8)
    for sp in ("top", "right", "left"): ax.spines[sp].set_visible(False)
    ax.set_title(title, fontsize=10, loc="left", fontweight="bold")
    fig.subplots_adjust(left=0.13, right=0.99, top=0.93, bottom=0.08)
    fig.savefig(os.path.join(OUT, fn)); plt.close(fig)

def col(log, k): return [r[k] for r in log]

HT = {0: "IDLE", 2: "NONSEQ", 3: "SEQ"}
def build_cmap(extra=None):
    d = {}
    for n in ["M_IDLE", "R_IDLE", "W_IDLE", "IDLE"]: d[n] = COL["idle"]
    for n in ["M_ADDR", "M_BURST", "M_LAST", "M_AR", "M_R", "M_AW", "M_W", "R_ACCESS", "W_ACCESS", "NONSEQ", "SEQ"]: d[n] = COL["active"]
    for n in ["R_WAIT", "M_B"]: d[n] = COL["wait"]
    for n in ["M_DONE", "R_DATA", "W_RESP"]: d[n] = COL["done"]
    d["M_ERR"] = COL["err"]
    d.update(extra or {})
    return d

def main():
    # ------------------------------ AHB ------------------------------
    log, mk, rbuf, mem = run_ahb()
    print("AHB read-back:", [hex(x) for x in rbuf[:4]], "mem:", [hex(x) for x in mem])
    assert rbuf[:4] == [0x11, 0x22, 0x33, 0x44], "AHB read-back mismatch"
    widths = dict(hclk=1, hresetn=1, start=1, mst=3, htrans=2, haddr=32, hwrite=1, hwdata=32, hrdata=32, hready=1,
                  hresp=1, irq=1, rs=2, ws=1, stb=1, we=1, adr=2, int_rx=1, int_tx=1)
    write_vcd(os.path.join(OUT, "ahb.vcd"), log, widths, "tb_ahb")
    cm = build_cmap()
    def ahb_rows():
        return [
            ("HCLK", "clk", col(log, "hclk")),
            ("HRESETn", "bit", col(log, "hresetn")),
            ("start", "bit", col(log, "start")),
            ("MASTER FSM", "state", col(log, "mst"), lambda q: AhbM.N[q]),
            ("HTRANS", "state", col(log, "htrans"), lambda q: HT[q]),
            ("HADDR", "bus", col(log, "haddr"), lambda q: "%08X" % q),
            ("HWRITE", "bit", col(log, "hwrite")),
            ("HWDATA", "bus", col(log, "hwdata"), lambda q: "%02X" % q),
            ("HRDATA", "bus", col(log, "hrdata"), lambda q: "%02X" % q),
            ("HREADY", "bit", col(log, "hready")),
            ("HRESP", "bit", col(log, "hresp")),
            ("IRQ (M_DONE)", "bit", col(log, "irq")),
            ("SLAVE RD FSM", "state", col(log, "rs"), lambda q: AhbS.RN[q]),
            ("SLAVE WR FSM", "state", col(log, "ws"), lambda q: AhbS.WN[q]),
            ("IP_STB", "bit", col(log, "stb")),
            ("IP_WE", "bit", col(log, "we")),
            ("IP_ADR", "bus", col(log, "adr"), lambda q: "%d" % q),
            ("IntRx_O", "bit", col(log, "int_rx")),
            ("IntTx_O", "bit", col(log, "int_tx")),
        ]
    W_END = mk["w_end"]; R_S = mk["t_rd"]; R_END = mk["r_end"]
    draw(ahb_rows(), 0, W_END + 3, "AHB Write Transfer (INCR4, byte) — Master/Slave Wrapper FSM", "ahb_write_wave.png", cm)
    draw(ahb_rows(), R_S - 2, min(len(log), R_END + 3), "AHB Read Transfer (INCR4, byte) — Master/Slave Wrapper FSM", "ahb_read_wave.png", cm)

    # ------------------------------ AXI ------------------------------
    log, mk, got = run_axi()
    print("AXI read-back:", [hex(x) for x in got])
    assert got == [0xA5A50000 + i for i in range(4)], "AXI read-back mismatch"
    widths = dict(aclk=1, aresetn=1, mw=3, awvalid=1, awready=1, awaddr=32, awlen=8, wvalid=1, wready=1, wdata=32,
                  wlast=1, bvalid=1, bready=1, sw=2, mr=3, arvalid=1, arready=1, araddr=32, arlen=8, rvalid=1,
                  rready=1, rdata=32, rlast=1, sr=2, stb=1, we=1, ack=1, int_rx=1, int_tx=1, done_w=1, done_r=1)
    write_vcd(os.path.join(OUT, "axi.vcd"), log, widths, "tb_axi")
    cm = build_cmap({"W_DATA": COL["wait"], "M_DONE": COL["done"]})
    h = lambda q: "%08X" % q
    w_rows = [
        ("ACLK", "clk", col(log, "aclk")),
        ("ARESETn", "bit", col(log, "aresetn")),
        ("MASTER WR FSM", "state", col(log, "mw"), lambda q: AxiMW.N[q]),
        ("AWVALID", "bit", col(log, "awvalid")),
        ("AWREADY", "bit", col(log, "awready")),
        ("AWADDR", "bus", col(log, "awaddr"), h),
        ("AWLEN", "bus", col(log, "awlen"), lambda q: "%d" % q),
        ("WVALID", "bit", col(log, "wvalid")),
        ("WREADY", "bit", col(log, "wready")),
        ("WDATA", "bus", col(log, "wdata"), h),
        ("WLAST", "bit", col(log, "wlast")),
        ("BVALID", "bit", col(log, "bvalid")),
        ("BREADY", "bit", col(log, "bready")),
        ("SLAVE WR FSM", "state", col(log, "sw"), lambda q: AxiSW.N[q]),
        ("IP_STB", "bit", col(log, "stb")),
        ("IP_WE", "bit", col(log, "we")),
        ("ACK", "bit", col(log, "ack")),
        ("IntTx_O", "bit", col(log, "int_tx")),
        ("DONE (M_DONE)", "bit", col(log, "done_w")),
    ]
    r_rows = [
        ("ACLK", "clk", col(log, "aclk")),
        ("ARESETn", "bit", col(log, "aresetn")),
        ("MASTER RD FSM", "state", col(log, "mr"), lambda q: AxiMR.N[q]),
        ("ARVALID", "bit", col(log, "arvalid")),
        ("ARREADY", "bit", col(log, "arready")),
        ("ARADDR", "bus", col(log, "araddr"), h),
        ("ARLEN", "bus", col(log, "arlen"), lambda q: "%d" % q),
        ("RVALID", "bit", col(log, "rvalid")),
        ("RREADY", "bit", col(log, "rready")),
        ("RDATA", "bus", col(log, "rdata"), h),
        ("RLAST", "bit", col(log, "rlast")),
        ("SLAVE RD FSM", "state", col(log, "sr"), lambda q: AxiSR.N[q]),
        ("IP_STB", "bit", col(log, "stb")),
        ("ACK", "bit", col(log, "ack")),
        ("IntRx_O", "bit", col(log, "int_rx")),
        ("DONE (M_DONE)", "bit", col(log, "done_r")),
    ]
    draw(w_rows, 0, mk["w_end"] + 3, "AXI4 Write Transaction (2 bursts x 2 beats) — Master/Slave Wrapper FSM", "axi_write_wave.png", cm)
    draw(r_rows, mk["r_start"] - 2, min(len(log), mk["r_end"] + 3), "AXI4 Read Transaction (1 burst x 4 beats) — Master/Slave Wrapper FSM", "axi_read_wave.png", cm)
    print("marks", mk)

if __name__ == "__main__":
    main()
