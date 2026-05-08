#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later OR Commercial
"""regmap_gen — turn a YAML register-map specification into a SystemVerilog
register file plus a matching C header.

The generated SV is a thin parameterisation wrapper around `axi4lite_slave`
that wires REG_ATTR / REG_RESET / port names per the YAML. The generated
C header gives software side-by-side `#define REG_<NAME>_OFFSET` and
field-mask macros so a driver does not have to hand-translate the SV.

YAML schema:

    name: my_block
    addr_width: 8
    data_width: 32
    registers:
      - name: CTRL
        offset: 0x00
        attr: RW          # RW | RO | RC | W1C
        reset: 0
        fields:           # optional bit-level documentation
          - name: START
            bits: [0, 0]
          - name: SOFT_RESET
            bits: [1, 1]
      - name: STATUS
        offset: 0x04
        attr: RO
        fields:
          - name: BUSY
            bits: [0, 0]
          - name: DONE
            bits: [1, 1]
          - name: ERR
            bits: [2, 2]
      - name: IRQ_STAT
        offset: 0x08
        attr: W1C
      - name: SCRATCH
        offset: 0x10
        attr: RW
        reset: 0xDEADBEEF

Run:
    python3 scripts/regmap_gen.py spec.yaml --sv my_block_regfile.sv \\
        --header my_block_regs.h

The script falls back to a tiny stdlib YAML parser if PyYAML is not
installed, supporting the schema above.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from typing import Any, Dict, List, Optional


ATTR_TO_CODE = {"RW": 0, "RO": 1, "RC": 2, "W1C": 3}


def _try_import_yaml():
    try:
        import yaml  # type: ignore
        return yaml
    except ImportError:
        return None


def _parse_yaml_minimal(text: str) -> Dict[str, Any]:
    """Stdlib-only parser for our schema. Supports:
        scalar: value
        list_key:
          - field: value
            field: value
            sub_list:
              - [a, b]
    """
    lines = [ln.rstrip() for ln in text.splitlines()]
    i = 0

    def indent_of(s: str) -> int:
        return len(s) - len(s.lstrip(" "))

    def parse_scalar(v: str):
        v = v.strip()
        if v == "":
            return None
        if v.startswith("[") and v.endswith("]"):
            inner = v[1:-1]
            return [parse_scalar(x) for x in inner.split(",")]
        if re.fullmatch(r"-?\d+", v):
            return int(v)
        if re.fullmatch(r"0x[0-9a-fA-F]+", v):
            return int(v, 16)
        if v.lower() in ("true", "false"):
            return v.lower() == "true"
        if v.startswith('"') and v.endswith('"'):
            return v[1:-1]
        return v

    def parse_block(base_indent: int):
        nonlocal i
        result: Dict[str, Any] = {}
        while i < len(lines):
            ln = lines[i]
            if ln.strip() == "":
                i += 1
                continue
            ind = indent_of(ln)
            if ind < base_indent:
                return result
            stripped = ln[ind:]
            if stripped.startswith("- "):
                return parse_list(base_indent)  # caller goofed; not a map here
            if ":" not in stripped:
                i += 1
                continue
            key, _, rest = stripped.partition(":")
            key = key.strip()
            rest = rest.strip()
            i += 1
            if rest == "":
                # Look ahead — list of dicts or nested map
                if i < len(lines) and lines[i].lstrip().startswith("- "):
                    result[key] = parse_list(ind + 2)
                else:
                    result[key] = parse_block(ind + 2)
            else:
                result[key] = parse_scalar(rest)
        return result

    def parse_list(base_indent: int) -> List[Any]:
        nonlocal i
        items: List[Any] = []
        while i < len(lines):
            ln = lines[i]
            if ln.strip() == "":
                i += 1
                continue
            ind = indent_of(ln)
            if ind < base_indent:
                return items
            stripped = ln[ind:]
            if not stripped.startswith("- "):
                return items
            after = stripped[2:]
            if ":" in after:
                # First field of an inline-style dict entry on the same line.
                key, _, rest = after.partition(":")
                lines[i] = " " * (ind + 2) + key.strip() + ":" + (
                    " " + rest.strip() if rest.strip() else "")
                items.append(parse_block(ind + 2))
            else:
                items.append(parse_scalar(after))
                i += 1
        return items

    return parse_block(0)


def load_spec(path: str) -> Dict[str, Any]:
    text = open(path, "r", encoding="utf-8").read()
    yaml = _try_import_yaml()
    if yaml is not None:
        spec = yaml.safe_load(text)
    else:
        spec = _parse_yaml_minimal(text)
    if not isinstance(spec, dict):
        raise SystemExit(f"regmap_gen: top-level YAML must be a mapping in {path}")
    return spec


def gen_sv(spec: Dict[str, Any]) -> str:
    name        = spec.get("name", "regmap_block")
    addr_w      = int(spec.get("addr_width", 8))
    data_w      = int(spec.get("data_width", 32))
    regs        = spec.get("registers", [])
    if not regs:
        raise SystemExit("regmap_gen: spec has no `registers:` list")

    bytes_per   = data_w // 8
    # Compute NUM_REGS as max_offset / bytes_per + 1
    max_off     = max(int(r["offset"]) for r in regs)
    num_regs    = (max_off // bytes_per) + 1

    # Build per-index attr + reset (default RW + 0 for unused indices).
    attr_codes  = [0] * num_regs
    reset_vals  = [0] * num_regs
    by_offset: Dict[int, Dict[str, Any]] = {}
    for r in regs:
        idx = int(r["offset"]) // bytes_per
        by_offset[idx] = r
        attr_codes[idx] = ATTR_TO_CODE.get(r.get("attr", "RW"), 0)
        reset_vals[idx] = int(r.get("reset", 0))

    # Pack REG_ATTR (2 bits per register, low-bit pair = reg 0).
    attr_bits = 0
    for i, c in enumerate(attr_codes):
        attr_bits |= (c & 0b11) << (2 * i)
    # Pack REG_RESET.
    reset_bits = 0
    for i, v in enumerate(reset_vals):
        reset_bits |= (v & ((1 << data_w) - 1)) << (data_w * i)

    sv = []
    sv.append(f"// SPDX-License-Identifier: GPL-3.0-or-later OR Commercial")
    sv.append(f"// AUTO-GENERATED by scripts/regmap_gen.py — do not edit by hand.")
    sv.append(f"// Source spec: name={name} addr_width={addr_w} data_width={data_w}")
    sv.append(f"// Registers ({len(regs)}):")
    for r in regs:
        sv.append(f"//   0x{int(r['offset']):02x}  {r['name']:<16}  {r.get('attr', 'RW'):<4}"
                  f"  reset=0x{int(r.get('reset', 0)):0{data_w//4}x}")
    sv.append("")
    sv.append(f"module {name}_regmap (")
    sv.append(f"  input  logic                    s_axi_aclk,")
    sv.append(f"  input  logic                    s_axi_aresetn,")
    sv.append(f"  input  logic [{addr_w-1}:0]   s_axi_awaddr,")
    sv.append(f"  input  logic [2:0]              s_axi_awprot,")
    sv.append(f"  input  logic                    s_axi_awvalid,")
    sv.append(f"  output logic                    s_axi_awready,")
    sv.append(f"  input  logic [{data_w-1}:0]   s_axi_wdata,")
    sv.append(f"  input  logic [{bytes_per-1}:0] s_axi_wstrb,")
    sv.append(f"  input  logic                    s_axi_wvalid,")
    sv.append(f"  output logic                    s_axi_wready,")
    sv.append(f"  output logic [1:0]              s_axi_bresp,")
    sv.append(f"  output logic                    s_axi_bvalid,")
    sv.append(f"  input  logic                    s_axi_bready,")
    sv.append(f"  input  logic [{addr_w-1}:0]   s_axi_araddr,")
    sv.append(f"  input  logic [2:0]              s_axi_arprot,")
    sv.append(f"  input  logic                    s_axi_arvalid,")
    sv.append(f"  output logic                    s_axi_arready,")
    sv.append(f"  output logic [{data_w-1}:0]   s_axi_rdata,")
    sv.append(f"  output logic [1:0]              s_axi_rresp,")
    sv.append(f"  output logic                    s_axi_rvalid,")
    sv.append(f"  input  logic                    s_axi_rready,")
    sv.append(f"  input  logic [{num_regs*data_w-1}:0] rd_payload_i,")
    sv.append(f"  input  logic                    slv_err_i,")
    sv.append(f"  output logic [{num_regs*data_w-1}:0] reg_storage_o,")
    sv.append(f"  output logic                    wr_event_o,")
    sv.append(f"  output logic [{addr_w-1}:0]   wr_event_addr_o,")
    sv.append(f"  output logic                    rd_event_o,")
    sv.append(f"  output logic [{addr_w-1}:0]   rd_event_addr_o")
    sv.append(f");")
    sv.append("")
    sv.append(f"  axi4lite_slave #(")
    sv.append(f"    .ADDR_WIDTH({addr_w}),")
    sv.append(f"    .DATA_WIDTH({data_w}),")
    sv.append(f"    .NUM_REGS  ({num_regs}),")
    sv.append(f"    .REG_ATTR  ({2*num_regs}'h{attr_bits:0{(2*num_regs+3)//4}x}),")
    sv.append(f"    .REG_RESET ({num_regs*data_w}'h{reset_bits:0{(num_regs*data_w+3)//4}x})")
    sv.append(f"  ) u_slave (")
    for sig in ["s_axi_aclk", "s_axi_aresetn", "s_axi_awaddr", "s_axi_awprot",
                "s_axi_awvalid", "s_axi_awready", "s_axi_wdata", "s_axi_wstrb",
                "s_axi_wvalid", "s_axi_wready", "s_axi_bresp", "s_axi_bvalid",
                "s_axi_bready", "s_axi_araddr", "s_axi_arprot", "s_axi_arvalid",
                "s_axi_arready", "s_axi_rdata", "s_axi_rresp", "s_axi_rvalid",
                "s_axi_rready", "rd_payload_i", "slv_err_i", "reg_storage_o",
                "wr_event_o", "wr_event_addr_o", "rd_event_o", "rd_event_addr_o"]:
        sv.append(f"    .{sig:<18}({sig}),")
    sv[-1] = sv[-1].rstrip(",")  # strip trailing comma
    sv.append(f"  );")
    sv.append(f"")
    sv.append(f"endmodule")
    sv.append("")
    return "\n".join(sv)


def gen_header(spec: Dict[str, Any]) -> str:
    name        = spec.get("name", "regmap_block").upper()
    data_w      = int(spec.get("data_width", 32))
    regs        = spec.get("registers", [])

    h = []
    h.append("/* SPDX-License-Identifier: GPL-3.0-or-later OR Commercial */")
    h.append("/* AUTO-GENERATED by scripts/regmap_gen.py - do not edit by hand. */")
    h.append("#ifndef " + name + "_REGS_H")
    h.append("#define " + name + "_REGS_H")
    h.append("")
    h.append("#include <stdint.h>")
    h.append("")
    for r in regs:
        rname = r["name"].upper()
        h.append(f"#define {name}_{rname}_OFFSET  0x{int(r['offset']):02x}u  /* {r.get('attr', 'RW')}"
                 f"  reset=0x{int(r.get('reset', 0)):0{data_w//4}x} */")
        for f in r.get("fields", []) or []:
            fname = f["name"].upper()
            hi, lo = (f["bits"][0], f["bits"][1]) if isinstance(f["bits"], list) else (f["bits"], f["bits"])
            width = (hi - lo) + 1
            mask  = ((1 << width) - 1) << lo
            h.append(f"#define {name}_{rname}_{fname}_SHIFT {lo}u")
            h.append(f"#define {name}_{rname}_{fname}_MASK  0x{mask:0{data_w//4}x}u")
    h.append("")
    h.append("#endif /* " + name + "_REGS_H */")
    h.append("")
    return "\n".join(h)


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("spec", help="path to YAML register-map spec")
    p.add_argument("--sv",     default=None, help="output SystemVerilog file")
    p.add_argument("--header", default=None, help="output C header file")
    args = p.parse_args()

    spec = load_spec(args.spec)
    sv = gen_sv(spec)
    hd = gen_header(spec)

    if args.sv:
        os.makedirs(os.path.dirname(os.path.abspath(args.sv)) or ".", exist_ok=True)
        open(args.sv, "w", encoding="utf-8").write(sv)
        print(f"[regmap_gen] wrote {args.sv} ({len(sv.splitlines())} lines)",
              file=sys.stderr)
    else:
        print(sv)

    if args.header:
        os.makedirs(os.path.dirname(os.path.abspath(args.header)) or ".", exist_ok=True)
        open(args.header, "w", encoding="utf-8").write(hd)
        print(f"[regmap_gen] wrote {args.header} ({len(hd.splitlines())} lines)",
              file=sys.stderr)
    elif not args.sv:
        # Print header if neither --sv nor --header was set.
        print(hd)

    return 0


if __name__ == "__main__":
    sys.exit(main())
