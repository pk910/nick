.PHONY: build build-gpu build-metal build-cuda-lib build-cuda clean test list-gpus help \
        initcode initcode-deposit initcode-exit mine-deposit .sys-asm-ref

BINARY_NAME=nick
GOBUILD=go build

# CUDA configuration
NVCC := $(shell which nvcc 2>/dev/null)
CUDA_PATH ?= /usr/local/cuda
# Override with: make build-cuda CUDA_ARCH=sm_XX
#   sm_70 Volta | sm_75 Turing | sm_80 Ampere | sm_89 Ada | sm_90 Hopper
CUDA_ARCH ?= sm_80

# Candidates per GPU thread (batch-inversion run length). MUST match
# miner.KernelIters in the Go code.
NICK_ITERS ?= 64

# CUDA tuning knobs (override on the make command line):
#   NICK_BLOCK - threads per block (e.g. 64/128/256)
#   MAXREG     - cap registers/thread to raise occupancy (e.g. 64/96/128); empty = off
NICK_BLOCK ?= 256
MAXREG ?=

all: build

## build: CPU-only build (no GPU libraries required)
build:
	@echo "Building CPU-only binary..."
	CGO_ENABLED=1 $(GOBUILD) -tags nocl -o $(BINARY_NAME) -v

## build-gpu: Build with OpenCL GPU support (Linux/macOS)
build-gpu:
	@echo "Building with OpenCL support..."
	CGO_ENABLED=1 $(GOBUILD) -o $(BINARY_NAME) -v

## build-metal: Build with Apple Silicon GPU (Metal) support (macOS, no Xcode needed)
build-metal:
	@echo "Building with Metal support (Apple Silicon)..."
	CGO_ENABLED=1 $(GOBUILD) -tags "metal nocl" -o $(BINARY_NAME) -v

## build-cuda-lib: Compile the CUDA kernel library (required before build-cuda)
build-cuda-lib:
ifndef NVCC
	$(error "nvcc not found. Install the CUDA Toolkit and ensure nvcc is in PATH")
endif
	@echo "Compiling CUDA kernel library (arch=$(CUDA_ARCH))..."
	cd miner/kernel && $(NVCC) -c -o nick_cuda.o cuda_launcher.cu \
		-arch=$(CUDA_ARCH) \
		-DNICK_ITERS=$(NICK_ITERS) \
		-DNICK_BLOCK=$(NICK_BLOCK) \
		$(if $(MAXREG),-maxrregcount=$(MAXREG)) \
		-O3 \
		--use_fast_math \
		-Xcompiler -O3,-fPIC
	cd miner/kernel && ar rcs libnick_cuda.a nick_cuda.o
	@echo "CUDA library built: miner/kernel/libnick_cuda.a"

## build-cuda: Build with CUDA + OpenCL support (Linux, NVIDIA). Needs libOpenCL too.
build-cuda: build-cuda-lib
	@echo "Building with CUDA support..."
	CGO_ENABLED=1 $(GOBUILD) -tags cuda -o $(BINARY_NAME) -v

## test: Run the math/self-check tests (no GPU needed)
test:
	go test -tags nocl ./...

## list-gpus: Build with OpenCL and list devices
list-gpus: build-gpu
	./$(BINARY_NAME) search --list-gpus

## clean: Remove build artifacts
clean:
	go clean
	rm -f $(BINARY_NAME)
	rm -f miner/kernel/*.o miner/kernel/*.a

# ---------------------------------------------------------------------------
# Contract init code (assembled from the sys-asm submodule)
#
# The predeploy contracts are geas assembly in the `sys-asm` submodule.
# Assembling ctor.eas yields `ctor ++ runtime` = the deployment init code,
# whose bytes determine the vanity address. These targets emit it 0x-prefixed,
# ready for `./nick search --initcode`.
#
# REF selects the sys-asm revision (a SHA is used from the local clone; a
# branch is fetched at runtime). Default = the pinned commit below.
#   make initcode-deposit              # pinned default (offline)
#   make initcode-deposit REF=<sha>    # any commit
#   make initcode-deposit REF=<branch> # latest branch tip (fetches)
# TODO: when the contracts land on sys-asm main, point
#       SYS_ASM_REMOTE=https://github.com/ethereum/sys-asm.git and REF=main.
# ---------------------------------------------------------------------------
GEAS           ?= $(shell command -v geas 2>/dev/null || echo "$$(go env GOPATH)/bin/geas")
SYS_ASM_DIR    ?= sys-asm
SYS_ASM_REMOTE ?= https://github.com/wemeetagain/sys-asm.git
REF            ?= 537b9c17d14705e77bc3f512e17dd253ad69b020
DEPOSIT_CTOR   := $(SYS_ASM_DIR)/src/builder_deposits/ctor.eas
EXIT_CTOR      := $(SYS_ASM_DIR)/src/builder_exits/ctor.eas

# Vanity search parameters (override on the command line). The target address
# is 0x0000-leading with a 00<eip> suffix; sig-r spells the EIP number too.
# EIP has no default -- set it, or pass SUFFIX/SIG_R explicitly.
#   make mine-deposit EIP=<num>                    # suffix 0x00<num>, sig-r 0x<num>
#   make mine-deposit SUFFIX=0xdead SIG_R=0xdead   # override directly
EIP         ?=
PREFIX      ?= 0x0000
SUFFIX      ?= $(if $(EIP),0x00$(EIP))
SIG_R       ?= $(if $(EIP),0x$(EIP))
SCORE       ?= 10
GPU_BACKEND ?= cuda
GPU_DEVICES ?= all
BATCH       ?= 67108864

# Ensure the sys-asm submodule is present, checked out at $(REF), and that geas
# is available. Run as a prerequisite of the init code / mining targets.
.sys-asm-ref:
	@test -e $(DEPOSIT_CTOR) || git submodule update --init $(SYS_ASM_DIR) >/dev/null 2>&1 || { \
		echo "ERROR: sys-asm submodule missing; run: git submodule update --init $(SYS_ASM_DIR)"; exit 1; }
	@if echo "$(REF)" | grep -qE '^[0-9a-fA-F]{7,40}$$'; then \
		git -C $(SYS_ASM_DIR) checkout -q $(REF) 2>/dev/null || { \
			git -C $(SYS_ASM_DIR) fetch -q $(SYS_ASM_REMOTE) $(REF) && \
			git -C $(SYS_ASM_DIR) checkout -q FETCH_HEAD; }; \
	else \
		git -C $(SYS_ASM_DIR) fetch -q $(SYS_ASM_REMOTE) $(REF) && \
		git -C $(SYS_ASM_DIR) checkout -q FETCH_HEAD; \
	fi
	@command -v $(GEAS) >/dev/null 2>&1 || test -x $(GEAS) || { \
		echo "ERROR: geas not found; run: go install github.com/fjl/geas/cmd/geas@latest"; exit 1; }

## initcode-deposit: Print 0x-prefixed builder-deposit init code (pipeable)
initcode-deposit: .sys-asm-ref
	@printf '0x%s\n' "$$($(GEAS) $(DEPOSIT_CTOR))"

## initcode-exit: Print 0x-prefixed builder-exit init code (pipeable)
initcode-exit: .sys-asm-ref
	@printf '0x%s\n' "$$($(GEAS) $(EXIT_CTOR))"

## initcode: Show both init codes with byte sizes and the assembled sys-asm commit
initcode: .sys-asm-ref
	@echo "sys-asm @ $$(git -C $(SYS_ASM_DIR) rev-parse --short HEAD) (REF=$(REF))"
	@dep=$$($(GEAS) $(DEPOSIT_CTOR)); echo "deposit ($$(( $${#dep}/2 )) bytes): 0x$$dep"
	@ext=$$($(GEAS) $(EXIT_CTOR));    echo "exit    ($$(( $${#ext}/2 )) bytes): 0x$$ext"

## mine-deposit: Assemble the deposit init code and run the GPU vanity search
mine-deposit: .sys-asm-ref
	@test -n "$(SUFFIX)" -a -n "$(SIG_R)" || { \
		echo "ERROR: which EIP do you want to mine for? Set EIP=<num>, e.g.:"; \
		echo "         make mine-deposit EIP=<num>"; \
		echo "       (or override SUFFIX=0x... SIG_R=0x... directly)"; exit 1; }
	@test -x ./$(BINARY_NAME) || { echo "ERROR: ./$(BINARY_NAME) not built; run: make build-cuda"; exit 1; }
	./$(BINARY_NAME) search --gpu --gpu-backend $(GPU_BACKEND) --gpu-devices $(GPU_DEVICES) \
		--batch-size $(BATCH) --initcode 0x$$($(GEAS) $(DEPOSIT_CTOR)) \
		--prefix $(PREFIX) --suffix $(SUFFIX) --sig-r $(SIG_R) --score $(SCORE)

## help: Show this help
help:
	@echo "Usage: make [target]"
	@echo ""
	@grep -E '^## ' Makefile | sed 's/## /  /'
	@echo ""
	@echo "GPU prerequisites:"
	@echo "  OpenCL (Linux): sudo apt install opencl-headers ocl-icd-opencl-dev"
	@echo "                  NVIDIA: also nvidia-opencl-dev / nvidia drivers"
	@echo "  CUDA   (Linux): NVIDIA CUDA Toolkit 11.0+ with nvcc in PATH"
	@echo ""
	@echo "Examples:"
	@echo "  make build-gpu && ./nick search --gpu --initcode 0x6000... --suffix 0xaaaa"
	@echo "  make build-cuda && ./nick search --gpu --gpu-backend cuda --gpu-devices all --initcode 0x..."
