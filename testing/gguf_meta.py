#!/usr/bin/env python3
"""Read GGUF KV metadata only (header, no tensor data) - fast, no model load."""
import struct
import sys

PATH = sys.argv[1]
f = open(PATH, "rb")

magic = f.read(4)
assert magic == b"GGUF", magic
version, n_tensors, n_kv = struct.unpack("<IQQ", f.read(20))


def rd(fmt):
    n = struct.calcsize(fmt)
    return struct.unpack(fmt, f.read(n))[0]


def rd_str():
    n = rd("<Q")
    return f.read(n).decode("utf-8", "replace")


# GGUF value type enum
U8, I8, U16, I16, U32, I32, F32, BOOL, STR, ARR, U64, I64, F64 = range(13)
SIMPLE = {U8: "<B", I8: "<b", U16: "<H", I16: "<h", U32: "<I", I32: "<i",
          F32: "<f", BOOL: "<?", U64: "<Q", I64: "<q", F64: "<d"}


def rd_val(t):
    if t in SIMPLE:
        return rd(SIMPLE[t])
    if t == STR:
        return rd_str()
    if t == ARR:
        et = rd("<I")
        n = rd("<Q")
        # don't materialize huge arrays (tokenizer vocab)
        if n > 64:
            for _ in range(n):
                rd_val(et)
            return f"<array len={n}>"
        return [rd_val(et) for _ in range(n)]
    raise ValueError(f"bad type {t}")


kv = {}
for _ in range(n_kv):
    k = rd_str()
    kv[k] = rd_val(rd("<I"))

print(f"tensors={n_tensors}  kv_count={n_kv}\n")
want = ("block_count", "attention", "ssm", "linear", "recurrent", "embedding_length",
        "head_count", "rope", "expert", "context_length", "architecture",
        "full_attention", "conv", "state")
for k, v in kv.items():
    if any(w in k.lower() for w in want):
        print(f"{k:55s} {v}")
