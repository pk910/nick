# CREATE2 vanity salt miner

Finds a 32-byte `salt` so that a contract deployed through a **CREATE2 factory**
(e.g. the EIP-7997 / Arachnid deterministic deployer at
`0x4e59b44847b379578588920cA78FbF26c0B4956C`) lands on a vanity address.

Unlike the Nick's-method search in the parent repo (which recovers an ECDSA
pubkey per candidate), CREATE2 mining is a **single Keccak-256 per candidate**,
so it's dramatically faster on the same GPU (~4–5× on our RTX 5090).

## Address formula

```
address = keccak256( 0xff ++ FACTORY(20) ++ salt(32) ++ keccak256(initcode)(32) )[12:32]
```

The 32-byte salt is split into a fixed random 24-byte **base** (pick a new one
each run — see note below) and an 8-byte big-endian **counter** the kernel
sweeps: `salt = base24 ++ counter`.

## Build

Requires the CUDA toolkit (`nvcc`).

```bash
make                        # builds ./c2find
make CUDA_ARCH=sm_90        # override arch (sm_80 Ampere, sm_89 Ada, sm_90 Hopper, sm_120 Blackwell)
```

## Usage

```bash
# initcode file = hex of the deployment init code (ctor ++ runtime), e.g. `geas ctor.eas`
geas ../../sys-asm/src/builder_deposits/ctor.eas > deposit.hex

# search: <initcode_hex_file> <base24_hex> [startCounter]
B17=0d B16LOWZERO=1 ./c2find deposit.hex "$(head -c24 /dev/urandom | xxd -p)" 0
```

On a hit it prints (and host-verifies) the `SALT` and resulting `ADDR`.

### Target pattern

Configured at the top of the kernel + via env:

| knob | meaning |
| --- | --- |
| (hardcoded) | `addr[0..1] == 0x0000` (prefix) and `addr[18..19] == 0x8282` (suffix tail) |
| `B17=<hex>` | `addr[17]` byte (default `0x00`) — e.g. `0d`→`…0d8282`, `0e`→`…0e8282` |
| `B16LOWZERO=1` | additionally require `addr[16]` low nibble `0` (one extra nibble; ~16× harder) |

The `0x82 0x82` tail is purpose-built for the EIP-8282 predeploys. For a
different pattern, edit the match in `mineKernel`/host check and the `FACTORY`
constant in `miner.cu`.

### Self-test / dump mode

```bash
./c2find deposit.hex <base24> dump <counter>   # prints the address for one exact salt
```

## Verify independently

Two independent Keccak-256 implementations (Ethereum uses **Keccak-256**, not
NIST SHA3-256 — the classic footgun) confirm any hit:

```bash
python3 verify.py addr 0x<salt> 0x<initcode> 0000 0d8282   # eth_utils.keccak
go run verify.go 0x<salt> 0x<initcode>                     # x/crypto sha3.NewLegacyKeccak256
```

## Deploy

The address depends only on `(factory, salt, initcode)` — **not** on the sender
or gas — so it is identical on every chain that has the factory. Deploy by
sending a normal tx: `to = factory`, `data = salt ++ initcode`, gas chosen at
send time.

> **Note on `base24`:** the kernel scans the 8-byte counter deterministically
> from `startCounter`. Re-running with the *same* base + initcode re-scans the
> same range, so use a **fresh random base24 per run** (and for parallel
> instances) to cover new ground — same idea as `--start-nonce` in the parent
> miner.
