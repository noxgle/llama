#!/usr/bin/env python3
"""CUDA GPU compute warmup for gpu-ready.sh.
Initializes the GPU compute pipeline after boot by creating a CUDA context,
allocating memory, and running a trivial computation. This ensures that the
first llama-server container after boot gets a properly initialized GPU,
preventing the "Post-Reboot Throughput Incident" where MTP speculative decoding
stays at ~1.2 tok/s with GPU stuck in P8 idle state.

Called by gpu-ready.sh after nvidia-smi -L succeeds.
Requires libcuda.so.1 (CUDA driver) and ctypes (Python stdlib).
"""

import ctypes
import sys


def cuda_warmup():
    libcuda = ctypes.CDLL("libcuda.so.1")

    result = libcuda.cuInit(0)
    if result != 0:
        print(f"ERROR: cuInit failed with code {result}", file=sys.stderr)
        return False

    count = ctypes.c_int()
    result = libcuda.cuDeviceGetCount(ctypes.byref(count))
    if result != 0 or count.value == 0:
        print("ERROR: No CUDA devices found", file=sys.stderr)
        return False

    dev = ctypes.c_int(0)

    name_buf = ctypes.create_string_buffer(256)
    libcuda.cuDeviceGetName(name_buf, 256, dev)
    dev_name = name_buf.value.decode()

    ctx = ctypes.c_void_p()
    result = libcuda.cuCtxCreate(ctypes.byref(ctx), 0, dev)
    if result != 0:
        print(f"ERROR: cuCtxCreate failed with code {result}", file=sys.stderr)
        return False

    ptr = ctypes.c_void_p()
    result = libcuda.cuMemAlloc(ctypes.byref(ptr), 1024)
    if result != 0:
        print(f"WARNING: cuMemAlloc failed with code {result}", file=sys.stderr)
    else:
        libcuda.cuMemFree(ptr)

    libcuda.cuCtxSetCurrent(ctx)
    libcuda.cuCtxDestroy(ctx)

    print(f"OK: CUDA warmup on {dev_name}")
    return True


if __name__ == "__main__":
    success = cuda_warmup()
    sys.exit(0 if success else 1)
