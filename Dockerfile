# syntax=docker/dockerfile:1

# ──────────────────────────────────────────────
# Stage 1: Build llama-server
# ──────────────────────────────────────────────
FROM nvidia/cuda:12.4.0-devel-ubuntu22.04 AS builder

ARG LLAMA_REPO=https://github.com/ggml-org/llama.cpp.git
ARG LLAMA_REF=master
ARG BUILD_JOBS=6

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        git cmake build-essential libcurl4-openssl-dev libssl-dev curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Clone pinned llama.cpp reference (tag, branch, or commit hash)
# Note: uses HTTP archive to support commit hashes (git fetch --depth 1 doesn't work for arbitrary hashes on GitHub)
RUN mkdir -p /tmp/llama-cpp-build && \
    curl -L "${LLAMA_REPO%.git}/archive/${LLAMA_REF}.tar.gz" | \
    tar -xz --strip-components=1 -C /tmp/llama-cpp-build

WORKDIR /tmp/llama-cpp-build

# Extract short commit hash from the source (embedded by cmake during build)
RUN echo "${LLAMA_REF}" | cut -c1-9

# Build llama-server with CUDA + curl support
# Set up CUDA driver stub for linking (actual driver comes from host at runtime)
RUN ln -sf /usr/local/cuda/lib64/stubs/libcuda.so /usr/local/cuda/lib64/stubs/libcuda.so.1 && \
    ln -sf /usr/local/cuda/lib64/stubs/libcuda.so /usr/local/cuda/lib64/libcuda.so.1 && \
    ldconfig
ENV LD_LIBRARY_PATH=/usr/local/cuda/lib64/stubs:/usr/local/cuda/lib64:${LD_LIBRARY_PATH}
RUN cmake -B build \
        -DLLAMA_CURL=ON \
        -DLLAMA_CUDA=ON \
        -DGGML_CUDA_NCCL=OFF \
        -DLLAMA_OPENSSL=ON \
        -DCMAKE_EXE_LINKER_FLAGS="-L/usr/local/cuda/lib64/stubs -Wl,-rpath,/usr/local/cuda/lib64" \
    && cmake --build build --config Release -j${BUILD_JOBS} -- llama-server

# ──────────────────────────────────────────────
# Stage 2: Runtime
# ──────────────────────────────────────────────
FROM nvidia/cuda:12.4.0-devel-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive

ENV LD_LIBRARY_PATH=/usr/local/cuda/lib64:${LD_LIBRARY_PATH}

# Copy llama-server binary
COPY --from=builder /tmp/llama-cpp-build/build/bin/llama-server /usr/local/bin/llama-server

# Copy all shared libraries built by llama.cpp (libmtmd, libggml, etc.)
COPY --from=builder /tmp/llama-cpp-build/build/bin/*.so* /usr/local/lib/

RUN ldconfig

# HuggingFace cache directory
RUN mkdir -p /root/.cache/huggingface/hub

EXPOSE 8089

ENTRYPOINT ["llama-server"]
