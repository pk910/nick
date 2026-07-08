# CREATE2 vanity salt miner (CUDA).
NVCC      ?= $(shell command -v nvcc 2>/dev/null || echo /usr/local/cuda/bin/nvcc)
# Override for your GPU: sm_80 Ampere | sm_89 Ada | sm_90 Hopper | sm_120 Blackwell.
# `native` targets the local GPU (needs CUDA 12.x).
CUDA_ARCH ?= native

c2find: miner.cu
	$(NVCC) -O3 -arch=$(CUDA_ARCH) -o $@ miner.cu

.PHONY: clean
clean:
	rm -f c2find
