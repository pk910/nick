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
# Contract init code (pre-assembled bytecode from the sys-asm submodule)
#
# sys-asm commits the assembled bytecode under bytecode/<contract>/ctor.hex
# precisely so consumers don't need the geas assembler (whose output could
# differ between versions). ctor.hex is the full deployment init code
# (`ctor ++ runtime`), whose bytes determine the vanity address. These
# targets emit it 0x-prefixed, ready for `./nick search --initcode`.
#
# By default the submodule is used as pinned by this repo's gitlink -- the
# init code bytes determine the vanity address, so the revision must not float
# silently. Bump the pin with: git submodule update --remote sys-asm
# (then commit the gitlink). REF optionally overrides the revision (a SHA is
# used from the local clone; a branch is fetched at runtime):
#   make initcode-deposit              # submodule as pinned (offline)
#   make initcode-deposit REF=<sha>    # any commit
#   make initcode-deposit REF=main     # latest upstream tip (fetches)
# ---------------------------------------------------------------------------
SYS_ASM_DIR    ?= sys-asm
SYS_ASM_REMOTE ?= https://github.com/ethereum/sys-asm.git
REF            ?=
DEPOSIT_HEX    := $(SYS_ASM_DIR)/bytecode/builder_deposits/ctor.hex
EXIT_HEX       := $(SYS_ASM_DIR)/bytecode/builder_exits/ctor.hex

# Vanity search parameters (override on the command line). The target address
# is 0x0000-leading with a 00<eip> suffix; sig-r spells the EIP number too.
# EIP has no default -- set it, or pass SUFFIX/SIG_R explicitly.
#   make mine-deposit EIP=<num>                    # suffix 0x00<num>, sig-r 0x<num>
#   make mine-deposit SUFFIX=0xdead SIG_R=0xdead   # override directly
#
# The GPU search picks a random start offset by default, so each run scans a
# fresh range. Set START_NONCE to pin the offset for a reproducible search
# (requires a miner with --start-nonce support):
#   make mine-deposit EIP=<num> START_NONCE=<n>
EIP         ?=
PREFIX      ?= 0x0000
SUFFIX      ?= $(if $(EIP),0x00$(EIP))
SIG_R       ?= $(if $(EIP),0x$(EIP))
SCORE       ?= 10
GPU_BACKEND ?= cuda
GPU_DEVICES ?= all
BATCH       ?= 67108864
START_NONCE ?=
RUNS_DIR    ?= runs

# Ensure the sys-asm submodule is present (checked out at $(REF) if set) and
# that the committed bytecode exists there. Run as a prerequisite of the init
# code / mining targets.
.sys-asm-ref:
	@test -e $(SYS_ASM_DIR)/.git || git submodule update --init $(SYS_ASM_DIR) >/dev/null 2>&1 || { \
		echo "ERROR: sys-asm submodule missing; run: git submodule update --init $(SYS_ASM_DIR)"; exit 1; }
	@if test -n "$(REF)"; then \
		if echo "$(REF)" | grep -qE '^[0-9a-fA-F]{7,40}$$'; then \
			git -C $(SYS_ASM_DIR) checkout -q $(REF) 2>/dev/null || { \
				git -C $(SYS_ASM_DIR) fetch -q $(SYS_ASM_REMOTE) $(REF) && \
				git -C $(SYS_ASM_DIR) checkout -q FETCH_HEAD; }; \
		else \
			git -C $(SYS_ASM_DIR) fetch -q $(SYS_ASM_REMOTE) $(REF) && \
			git -C $(SYS_ASM_DIR) checkout -q FETCH_HEAD; \
		fi; \
	fi
	@test -s $(DEPOSIT_HEX) -a -s $(EXIT_HEX) || { \
		echo "ERROR: no committed bytecode at sys-asm $$(git -C $(SYS_ASM_DIR) rev-parse --short HEAD) ($(DEPOSIT_HEX) missing);"; \
		echo "       the builder contracts' bytecode is only committed on newer sys-asm revisions"; exit 1; }

## initcode-deposit: Print 0x-prefixed builder-deposit init code (pipeable)
initcode-deposit: .sys-asm-ref
	@printf '0x%s\n' "$$(cat $(DEPOSIT_HEX))"

## initcode-exit: Print 0x-prefixed builder-exit init code (pipeable)
initcode-exit: .sys-asm-ref
	@printf '0x%s\n' "$$(cat $(EXIT_HEX))"

## initcode: Show both init codes with byte sizes and the sys-asm commit
initcode: .sys-asm-ref
	@echo "sys-asm @ $$(git -C $(SYS_ASM_DIR) rev-parse --short HEAD)$(if $(REF), (REF=$(REF)))"
	@dep=$$(cat $(DEPOSIT_HEX)); echo "deposit ($$(( $${#dep}/2 )) bytes): 0x$$dep"
	@ext=$$(cat $(EXIT_HEX));    echo "exit    ($$(( $${#ext}/2 )) bytes): 0x$$ext"

## mine-deposit: Run the GPU vanity search on the committed deposit init code
mine-deposit: .sys-asm-ref
	@test -n "$(SUFFIX)" -a -n "$(SIG_R)" || { \
		echo "ERROR: which EIP do you want to mine for? Set EIP=<num>, e.g.:"; \
		echo "         make mine-deposit EIP=<num>"; \
		echo "       (or override SUFFIX=0x... SIG_R=0x... directly)"; exit 1; }
	@test -x ./$(BINARY_NAME) || { echo "ERROR: ./$(BINARY_NAME) not built; run: make build-cuda"; exit 1; }
	@mkdir -p $(RUNS_DIR)
	@ts=$$(date +%Y-%m-%d_%H%M); log=$(RUNS_DIR)/mine-deposit-$$ts.log; res=$(RUNS_DIR)/mine-deposit-$$ts.result.txt; \
	echo "logging to $$log"; \
	./$(BINARY_NAME) search --gpu --gpu-backend $(GPU_BACKEND) --gpu-devices $(GPU_DEVICES) \
		--batch-size $(BATCH) --initcode 0x$$(cat $(DEPOSIT_HEX)) \
		--prefix $(PREFIX) --suffix $(SUFFIX) --sig-r $(SIG_R) --score $(SCORE) \
		$(if $(START_NONCE),--start-nonce $(START_NONCE)) 2>&1 | tee $$log; \
	awk '/^Found!/{f=1} f{print}' $$log > $$res; \
	echo "result saved: $$res"

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
