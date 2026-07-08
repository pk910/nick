#!/usr/bin/env python3
# Independent CREATE2 verifier using eth_utils.keccak (Keccak-256, not SHA3).
import sys
from eth_utils import keccak, to_checksum_address

FACTORY = bytes.fromhex("4e59b44847b379578588920cA78FbF26c0B4956C")

def create2(salt: bytes, initcode: bytes):
    ich = keccak(initcode)
    pre = b"\xff" + FACTORY + salt + ich
    assert len(pre) == 85, len(pre)
    return ich, keccak(pre)[12:]

if __name__ == "__main__":
    mode = sys.argv[1]
    if mode == "hash":
        initcode = bytes.fromhex(sys.argv[2].removeprefix("0x"))
        print("0x" + keccak(initcode).hex())
    elif mode == "addr":
        salt = bytes.fromhex(sys.argv[2].removeprefix("0x"))
        initcode = bytes.fromhex(sys.argv[3].removeprefix("0x"))
        ich, addr = create2(salt, initcode)
        print("initcodehash 0x" + ich.hex())
        print("addr        0x" + addr.hex())
        print("checksum   ", to_checksum_address(addr))
        h = addr.hex()
        # optional expected prefix/suffix hex strings (sys.argv[4]=prefix, [5]=suffix)
        prefix = sys.argv[4] if len(sys.argv) > 4 else "0000"
        suffix = sys.argv[5] if len(sys.argv) > 5 else "008282"
        ok = h.startswith(prefix.lower()) and h.endswith(suffix.lower())
        print(f"prefix_ok {h.startswith(prefix.lower())} suffix_ok {h.endswith(suffix.lower())} pattern_ok {ok}")
