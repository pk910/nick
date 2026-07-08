package main
// Second independent CREATE2 verifier: golang.org/x/crypto/sha3 NewLegacyKeccak256.
import (
	"encoding/hex"
	"fmt"
	"os"
	"strings"
	"golang.org/x/crypto/sha3"
)
func keccak(b []byte) []byte { h := sha3.NewLegacyKeccak256(); h.Write(b); return h.Sum(nil) }
func dh(s string) []byte { b, _ := hex.DecodeString(strings.TrimPrefix(s, "0x")); return b }
func main() {
	salt := dh(os.Args[1]); initcode := dh(os.Args[2])
	factory := dh("4e59b44847b379578588920cA78FbF26c0B4956C")
	ich := keccak(initcode)
	pre := append([]byte{0xff}, factory...); pre = append(pre, salt...); pre = append(pre, ich...)
	full := keccak(pre); addr := full[12:]
	ok := addr[0]==0 && addr[1]==0 && addr[17]==0 && addr[18]==0x82 && addr[19]==0x82
	fmt.Printf("initcodehash 0x%x\naddr 0x%x\npattern_ok %v\n", ich, addr, ok)
}
