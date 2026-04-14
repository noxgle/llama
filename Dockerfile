# syntax=docker/dockerfile:1

# ──────────────────────────────────────────────
# Stage 1: Build llama-server
# ──────────────────────────────────────────────
FROM nvidia/cuda:12.4.0-devel-ubuntu22.04 AS builder

ARG PR_NUMBER=21343
ARG BUILD_JOBS=6

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        git cmake build-essential libcurl4-openssl-dev libssl-dev curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install GitHub CLI for PR checkout
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg && \
    chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) \
        signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] \
        https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list && \
    apt-get update && apt-get install -y gh && \
    rm -rf /var/lib/apt/lists/*

# Clone & checkout PR
RUN git clone --depth 50 https://github.com/ggml-org/llama.cpp.git /tmp/llama-cpp-build

WORKDIR /tmp/llama-cpp-build

ARG GH_TOKEN=""
RUN if [ -n "$GH_TOKEN" ]; then \
        gh pr checkout ${PR_NUMBER}; \
    else \
        echo "No GH_TOKEN provided, falling back to git fetch" && \
        git fetch origin pull/${PR_NUMBER}/head && \
        git checkout FETCH_HEAD; \
    fi

# Apply PR #20050 patch (KV cache retry fix)
RUN curl -sL https://github.com/ggml-org/llama.cpp/pull/20050.diff -o /tmp/20050.patch && \
    git apply /tmp/20050.patch || echo "Patch may have conflicts or already applied"

# Build llama-server with CUDA + curl support
# Set up CUDA driver stub for linking (actual driver comes from host at runtime)
RUN ln -sf /usr/local/cuda/lib64/stubs/libcuda.so /usr/local/cuda/lib64/stubs/libcuda.so.1 && \
    ln -sf /usr/local/cuda/lib64/stubs/libcuda.so /usr/local/cuda/lib64/libcuda.so.1 && \
    ldconfig
ENV LD_LIBRARY_PATH=/usr/local/cuda/lib64/stubs:/usr/local/cuda/lib64:${LD_LIBRARY_PATH}
RUN cmake -B build \
        -DLLAMA_CURL=ON \
        -DLLAMA_CUDA=ON \
        -DLLAMA_OPENSSL=ON \
        -DCMAKE_EXE_LINKER_FLAGS="-L/usr/local/cuda/lib64/stubs -Wl,-rpath,/usr/local/cuda/lib64" \
    && cmake --build build --config Release -j${BUILD_JOBS} -- llama-server

# ──────────────────────────────────────────────
# Stage 2: Runtime
# ──────────────────────────────────────────────
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Install CUDA runtime libraries (userspace only, no kernel modules)
COPY --from=builder /usr/local/cuda/lib64/libcudart.so.* /usr/local/cuda/lib64/
COPY --from=builder /usr/local/cuda/lib64/libcublas.so.* /usr/local/cuda/lib64/
COPY --from=builder /usr/local/cuda/lib64/libcublasLt.so.* /usr/local/cuda/lib64/

RUN apt-get update && apt-get install -y --no-install-recommends \
        libcurl4 libgomp1 ca-certificates \
    && ldconfig \
    && rm -rf /var/lib/apt/lists/*

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
