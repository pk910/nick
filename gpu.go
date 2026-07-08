package main

import (
	"bytes"
	crand "crypto/rand"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"math/big"
	"strconv"
	"strings"
	"time"

	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/pk910/nick/miner"
)

// gpuRunner is satisfied by the OpenCL, single-CUDA and multi-CUDA miners.
type gpuRunner interface {
	Mine(p *miner.Precompute, prefix, suffix []byte, startNonce uint64) (*miner.GPUResult, time.Duration, error)
	Close()
}

// legacyTx builds the deployment transaction for a given signature s. The
// sighash depends only on the fixed fields (nonce, gas, data, ...), not on s,
// r or v, so it is stable across the whole search.
func (t *task) legacyTx(s *big.Int) types.LegacyTx {
	return types.LegacyTx{
		Nonce:    0,
		GasPrice: newGwei(t.gasPrice),
		Gas:      t.gasLimit,
		To:       nil,
		Value:    big.NewInt(0),
		Data:     t.initcode,
		V:        big.NewInt(27),
		R:        new(big.Int).Set(t.sigR),
		S:        new(big.Int).Set(s),
	}
}

// runGPU runs the search on the GPU. Candidate k corresponds to signature
// s = sigS + k; the kernel recovers the deployer and derives the contract
// address for each k in the batch (see miner/precompute.go).
func (t *task) runGPU() error {
	if len(t.prefix) == 0 && len(t.suffix) == 0 {
		return fmt.Errorf("specify at least --prefix or --suffix to search for")
	}

	inner := t.legacyTx(t.sigS)
	z := sighash(types.NewTx(&inner))
	p, err := miner.NewPrecompute(z[:], t.sigR, new(big.Int).Set(t.sigS))
	if err != nil {
		return fmt.Errorf("precompute failed: %w", err)
	}

	runner, totalBatch, name, err := t.makeMiner()
	if err != nil {
		return fmt.Errorf("failed to initialize GPU miner: %w", err)
	}
	defer runner.Close()

	fmt.Printf("GPU mining on %s (batch size %d)\n", name, totalBatch)
	fmt.Printf("Target: prefix=0x%x suffix=0x%x\n", t.prefix, t.suffix)

	// The GPU scans candidates sequentially (s = sigS + nonce, for nonce =
	// start, start+1, ...), so re-running with the same start re-scans the
	// identical range and returns the same address. Default to a random start
	// so repeated runs explore fresh regions; --start-nonce pins it when a
	// reproducible search is wanted.
	nonce := t.startNonce
	if nonce == 0 {
		var seed [8]byte
		if _, err := crand.Read(seed[:]); err != nil {
			return fmt.Errorf("failed to seed random start nonce: %w", err)
		}
		nonce = binary.BigEndian.Uint64(seed[:])
	}
	fmt.Printf("Start nonce: %d\n", nonce)

	start := time.Now()
	lastLog := start
	var total uint64
	for {
		res, _, err := runner.Mine(p, t.prefix, t.suffix, nonce)
		if err != nil {
			return fmt.Errorf("mining error: %w", err)
		}
		nonce += uint64(totalBatch)
		total += uint64(totalBatch)

		if res != nil {
			fmt.Println()
			return t.reportGPUHit(p, res)
		}

		if time.Since(lastLog) > time.Second {
			secs := time.Since(start).Seconds()
			fmt.Printf("\rSearched %d candidates, %.2f MH/s", total, float64(total)/secs/1e6)
			lastLog = time.Now()
		}
	}
}

// reportGPUHit reconstructs the full transaction for the winning candidate,
// verifies it on the CPU against the kernel's address, and prints it.
func (t *task) reportGPUHit(p *miner.Precompute, res *miner.GPUResult) error {
	s := new(big.Int).Add(p.SBase, new(big.Int).SetUint64(res.Nonce))
	inner := t.legacyTx(s)
	tx := types.NewTx(&inner)

	sender, err := recoverPlain(sighash(tx), inner.R, inner.S, inner.V)
	if err != nil {
		return fmt.Errorf("failed to recover sender: %w", err)
	}
	addr := crypto.CreateAddress(sender, 0)

	if !bytes.Equal(addr.Bytes(), res.Address[:]) {
		fmt.Printf("WARNING: GPU address 0x%x does not match CPU recomputation %v — kernel bug, do NOT use this result\n",
			res.Address[:], addr)
	}

	score := compare(t.prefix, addr[:]) + len(t.suffix)*2
	txjson, _ := json.MarshalIndent(tx, "", "  ")
	fmt.Printf("Found! (score %d, k=%d)\nSender: %v\nAddress: %v\nTx:\n%v\n",
		score, res.Nonce, sender, addr, string(txjson))
	return nil
}

// makeMiner constructs the GPU miner for the configured backend and returns it
// along with its combined batch size and a display name.
func (t *task) makeMiner() (gpuRunner, int, string, error) {
	tryCUDA := func() (gpuRunner, int, string, error) {
		ids, err := t.cudaDeviceIDs()
		if err != nil {
			return nil, 0, "", err
		}
		if len(ids) > 1 {
			mm, err := miner.NewMultiGPUMiner(ids, t.batchSize)
			if err != nil {
				return nil, 0, "", err
			}
			return mm, mm.TotalBatchSize() * miner.KernelIters, strings.Join(mm.DeviceNames(), ", "), nil
		}
		cm, err := miner.NewCUDAMiner(ids[0], t.batchSize)
		if err != nil {
			return nil, 0, "", err
		}
		return cm, cm.BatchSize() * miner.KernelIters, cm.DeviceName(), nil
	}
	tryOpenCL := func() (gpuRunner, int, string, error) {
		gm, err := miner.NewGPUMiner(t.gpuDevice, t.batchSize)
		if err != nil {
			return nil, 0, "", err
		}
		return gm, gm.BatchSize() * miner.KernelIters, gm.DeviceName(), nil
	}
	tryMetal := func() (gpuRunner, int, string, error) {
		mm, err := miner.NewMetalMiner(t.gpuDevice, t.batchSize)
		if err != nil {
			return nil, 0, "", err
		}
		return mm, mm.BatchSize() * miner.MetalKernelIters, mm.DeviceName(), nil
	}

	switch strings.ToLower(t.gpuBackend) {
	case "cuda":
		return tryCUDA()
	case "metal":
		return tryMetal()
	case "opencl", "":
		return tryOpenCL()
	case "auto":
		if r, b, n, err := tryMetal(); err == nil {
			return r, b, n, nil
		}
		if r, b, n, err := tryCUDA(); err == nil {
			return r, b, n, nil
		}
		return tryOpenCL()
	default:
		return nil, 0, "", fmt.Errorf("unknown gpu-backend %q (use opencl, cuda, metal, or auto)", t.gpuBackend)
	}
}

// cudaDeviceIDs resolves the CUDA device selection (--gpu-device / --gpu-devices).
func (t *task) cudaDeviceIDs() ([]int, error) {
	if t.gpuDevices == "" {
		return []int{t.gpuDevice}, nil
	}
	if strings.EqualFold(t.gpuDevices, "all") {
		gpus, err := miner.ListCUDAGPUs()
		if err != nil {
			return nil, err
		}
		if len(gpus) == 0 {
			return nil, fmt.Errorf("no CUDA devices found")
		}
		ids := make([]int, len(gpus))
		for i := range gpus {
			ids[i] = i
		}
		return ids, nil
	}
	var ids []int
	for _, part := range strings.Split(t.gpuDevices, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		n, err := strconv.Atoi(part)
		if err != nil {
			return nil, fmt.Errorf("invalid device index %q", part)
		}
		ids = append(ids, n)
	}
	if len(ids) == 0 {
		return nil, fmt.Errorf("no devices parsed from %q", t.gpuDevices)
	}
	return ids, nil
}

// listGPUs prints the available GPU devices for the chosen backend.
func listGPUs(backend, devices string) error {
	if strings.EqualFold(backend, "cuda") {
		gpus, err := miner.ListCUDAGPUs()
		if err != nil {
			return err
		}
		fmt.Printf("CUDA devices (%d):\n", len(gpus))
		for _, g := range gpus {
			fmt.Printf("  [%d] %s — %d SMs, %.1f GB\n",
				g.Index, g.Name, g.ComputeUnits, float64(g.TotalMemory)/1e9)
		}
		return nil
	}
	if strings.EqualFold(backend, "metal") {
		gpus, err := miner.ListMetalGPUs()
		if err != nil {
			return err
		}
		fmt.Printf("Metal devices (%d):\n", len(gpus))
		for _, g := range gpus {
			fmt.Printf("  [%d] %s (%s)\n", g.Index, g.Name, g.Vendor)
		}
		return nil
	}
	gpus, err := miner.ListGPUs()
	if err != nil {
		return err
	}
	fmt.Printf("OpenCL GPU devices (%d):\n", len(gpus))
	for _, g := range gpus {
		fmt.Printf("  [%d] %s (%s) — %d CUs\n", g.Index, g.Name, g.Vendor, g.ComputeUnits)
	}
	return nil
}
