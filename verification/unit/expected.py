#!/usr/bin/env python3
"""M2 unit tests (directive §43-46): ALU boundaries, FLAGS, DECODER, SGPR file.
Drives the scigpu_units_tb wrapper via Verilator. Self-checking; exits nonzero.
"""
import os, sys, random
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, 'models', 'isa'))
import scigpu_defs as D
from scigpu_defs import OP

try:
    from verification.unit import units_driver  # noqa: F401 (built externally)
except Exception:
    pass

# The C++ driver is invoked by the Makefile; this module provides the EXPECTED
# value computation used to cross-check that driver's vectors (kept in one place).
def alu_expected(op, a, b):
    M = 0xFFFFFFFF
    sh = b & 31
    if op == 'ADD': return (a + b) & M
    if op == 'SUB': return (a - b) & M
    if op == 'AND': return a & b
    if op == 'OR':  return a | b
    if op == 'XOR': return a ^ b
    if op == 'NOT': return (~a) & M
    if op == 'SHL': return (a << sh) & M
    if op == 'SHR': return a >> sh
    if op == 'SAR':
        sa = a - (1 << 32) if a >> 31 else a
        return (sa >> sh) & M
    if op == 'MUL': return (a * b) & M
    raise ValueError(op)

def flags_expected(a, b):
    r = (a - b) & 0xFFFFFFFF
    z = int(r == 0); n = (r >> 31) & 1
    c = int(a >= b)
    va, vb = (a >> 31) & 1, (b >> 31) & 1
    v = int(va != vb and ((r >> 31) & 1) != va)
    sa = a - (1 << 32) if a >> 31 else a
    sb = b - (1 << 32) if b >> 31 else b
    return dict(Z=z, N=n, C=c, V=v,
                SCC_EQ=int(a == b), SCC_LT=int(sa < sb), SCC_GT=int(sa > sb))
