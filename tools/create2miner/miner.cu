// CREATE2 vanity salt miner (Keccak-256).
// Finds salt s.t. address = keccak256(0xff ++ FACTORY ++ salt ++ keccak256(initcode))[12:]
// satisfies: addr[0]=0x00 addr[1]=0x00 addr[17]=0x00 addr[18]=0x82 addr[19]=0x82.
//
// Preimage layout (85 bytes):
//   [0]      = 0xff
//   [1..21)  = FACTORY (20 bytes)
//   [21..53) = salt (32 bytes): [21..45) fixed random base, [45..53) = 8-byte BE counter
//   [53..85) = keccak256(initcode) (32 bytes)
// Keccak-256 rate=136, single block (85<136). Pad: byte85=0x01, byte135=0x80.
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <cuda_runtime.h>

__device__ __constant__ uint64_t RC[24] = {
  0x0000000000000001ULL,0x0000000000008082ULL,0x800000000000808aULL,0x8000000080008000ULL,
  0x000000000000808bULL,0x0000000080000001ULL,0x8000000080008081ULL,0x8000000000008009ULL,
  0x000000000000008aULL,0x0000000000000088ULL,0x0000000080008009ULL,0x000000008000000aULL,
  0x000000008000808bULL,0x800000000000008bULL,0x8000000000008089ULL,0x8000000000008003ULL,
  0x8000000000008002ULL,0x8000000000000080ULL,0x000000000000800aULL,0x800000008000000aULL,
  0x8000000080008081ULL,0x8000000000008080ULL,0x0000000080000001ULL,0x8000000080008008ULL
};
__device__ __constant__ int PILN[24]={10,7,11,17,18,3,5,16,8,21,24,4,15,23,19,13,12,2,20,14,22,9,6,1};
__device__ __constant__ int RHO[24]={1,3,6,10,15,21,28,36,45,55,2,14,27,41,56,8,25,43,62,18,39,61,20,44};
// Full 17-lane base preimage (little-endian), counter region and pad included.
__device__ __constant__ uint64_t d_base[17];

__device__ __forceinline__ uint64_t rotl64(uint64_t x, int o){ return (x<<o)|(x>>(64-o)); }

__device__ __forceinline__ void keccakf(uint64_t st[25]){
  #pragma unroll 1
  for(int r=0;r<24;r++){
    uint64_t bc0,bc1,bc2,bc3,bc4,t,b;
    bc0 = st[0]^st[5]^st[10]^st[15]^st[20];
    bc1 = st[1]^st[6]^st[11]^st[16]^st[21];
    bc2 = st[2]^st[7]^st[12]^st[17]^st[22];
    bc3 = st[3]^st[8]^st[13]^st[18]^st[23];
    bc4 = st[4]^st[9]^st[14]^st[19]^st[24];
    t = bc4 ^ rotl64(bc1,1); st[0]^=t; st[5]^=t; st[10]^=t; st[15]^=t; st[20]^=t;
    t = bc0 ^ rotl64(bc2,1); st[1]^=t; st[6]^=t; st[11]^=t; st[16]^=t; st[21]^=t;
    t = bc1 ^ rotl64(bc3,1); st[2]^=t; st[7]^=t; st[12]^=t; st[17]^=t; st[22]^=t;
    t = bc2 ^ rotl64(bc4,1); st[3]^=t; st[8]^=t; st[13]^=t; st[18]^=t; st[23]^=t;
    t = bc3 ^ rotl64(bc0,1); st[4]^=t; st[9]^=t; st[14]^=t; st[19]^=t; st[24]^=t;
    // rho + pi (fully unrolled, literal indices -> state stays in registers)
    t=st[1];
    b=st[10]; st[10]=rotl64(t,1);  t=b;
    b=st[7];  st[7]=rotl64(t,3);   t=b;
    b=st[11]; st[11]=rotl64(t,6);  t=b;
    b=st[17]; st[17]=rotl64(t,10); t=b;
    b=st[18]; st[18]=rotl64(t,15); t=b;
    b=st[3];  st[3]=rotl64(t,21);  t=b;
    b=st[5];  st[5]=rotl64(t,28);  t=b;
    b=st[16]; st[16]=rotl64(t,36); t=b;
    b=st[8];  st[8]=rotl64(t,45);  t=b;
    b=st[21]; st[21]=rotl64(t,55); t=b;
    b=st[24]; st[24]=rotl64(t,2);  t=b;
    b=st[4];  st[4]=rotl64(t,14);  t=b;
    b=st[15]; st[15]=rotl64(t,27); t=b;
    b=st[23]; st[23]=rotl64(t,41); t=b;
    b=st[19]; st[19]=rotl64(t,56); t=b;
    b=st[13]; st[13]=rotl64(t,8);  t=b;
    b=st[12]; st[12]=rotl64(t,25); t=b;
    b=st[2];  st[2]=rotl64(t,43);  t=b;
    b=st[20]; st[20]=rotl64(t,62); t=b;
    b=st[14]; st[14]=rotl64(t,18); t=b;
    b=st[22]; st[22]=rotl64(t,39); t=b;
    b=st[9];  st[9]=rotl64(t,61);  t=b;
    b=st[6];  st[6]=rotl64(t,20);  t=b;
    b=st[1];  st[1]=rotl64(t,44);
    // chi
    #pragma unroll
    for(int j=0;j<25;j+=5){
      uint64_t a0=st[j],a1=st[j+1],a2=st[j+2],a3=st[j+3],a4=st[j+4];
      st[j]  =a0^((~a1)&a2);
      st[j+1]=a1^((~a2)&a3);
      st[j+2]=a2^((~a3)&a4);
      st[j+3]=a3^((~a4)&a0);
      st[j+4]=a4^((~a0)&a1);
    }
    st[0]^=RC[r];
  }
}

// Debug: run device keccak for a single counter and write full 32-byte output.
__global__ void dumpKernel(uint64_t counter, uint8_t* out32){
  uint64_t st[25];
  #pragma unroll
  for(int i=0;i<17;i++) st[i]=d_base[i];
  #pragma unroll
  for(int i=17;i<25;i++) st[i]=0;
  uint8_t cb0=(uint8_t)(counter>>56),cb1=(uint8_t)(counter>>48),cb2=(uint8_t)(counter>>40),
          cb3=(uint8_t)(counter>>32),cb4=(uint8_t)(counter>>24),cb5=(uint8_t)(counter>>16),
          cb6=(uint8_t)(counter>>8),cb7=(uint8_t)(counter);
  st[5] |= ((uint64_t)cb0)<<40 | ((uint64_t)cb1)<<48 | ((uint64_t)cb2)<<56;
  st[6] |= ((uint64_t)cb3) | ((uint64_t)cb4)<<8 | ((uint64_t)cb5)<<16 | ((uint64_t)cb6)<<24 | ((uint64_t)cb7)<<32;
  keccakf(st);
  for(int k=0;k<4;k++) for(int b=0;b<8;b++) out32[k*8+b]=(uint8_t)(st[k]>>(8*b));
}

// Match params: prefix out[12]=out[13]=0x00 always. Suffix configurable:
//   b16low: if 1, require (out[28] & 0x0f)==0  (byte16 low nibble zero)
//   b17: required value of out[29] (address byte17)
//   out[30]=0x82, out[31]=0x82 always.
__global__ void mineKernel(uint64_t startCounter, uint64_t total,
                           int b16low, unsigned int b17,
                           unsigned long long* foundCounter, int* foundFlag){
  uint64_t idx = blockIdx.x*(uint64_t)blockDim.x + threadIdx.x;
  if(idx >= total) return;
  uint64_t counter = startCounter + idx;

  uint64_t st[25];
  #pragma unroll
  for(int i=0;i<17;i++) st[i]=d_base[i];
  #pragma unroll
  for(int i=17;i<25;i++) st[i]=0;

  // counter -> preimage bytes 45..52 big-endian.
  // byte45 -> lane5 pos5, byte46 -> lane5 pos6, byte47 -> lane5 pos7,
  // byte48..52 -> lane6 pos0..4.
  uint8_t cb0=(uint8_t)(counter>>56),cb1=(uint8_t)(counter>>48),cb2=(uint8_t)(counter>>40),
          cb3=(uint8_t)(counter>>32),cb4=(uint8_t)(counter>>24),cb5=(uint8_t)(counter>>16),
          cb6=(uint8_t)(counter>>8),cb7=(uint8_t)(counter);
  st[5] |= ((uint64_t)cb0)<<40 | ((uint64_t)cb1)<<48 | ((uint64_t)cb2)<<56;
  st[6] |= ((uint64_t)cb3) | ((uint64_t)cb4)<<8 | ((uint64_t)cb5)<<16 | ((uint64_t)cb6)<<24 | ((uint64_t)cb7)<<32;

  keccakf(st);

  // address = out[12..32]; out byte b in lane b/8 pos b%8.
  uint64_t l1=st[1], l3=st[3];
  uint8_t o12=(uint8_t)(l1>>32), o13=(uint8_t)(l1>>40);
  uint8_t o28=(uint8_t)(l3>>32), o29=(uint8_t)(l3>>40), o30=(uint8_t)(l3>>48), o31=(uint8_t)(l3>>56);
  bool okB16 = (!b16low) || ((o28 & 0x0f)==0);
  if(o12==0x00 && o13==0x00 && okB16 && o29==(uint8_t)b17 && o30==0x82 && o31==0x82){
    if(atomicCAS(foundFlag,0,1)==0) *foundCounter=(unsigned long long)counter;
  }
}

// ---------------- host ----------------
static uint64_t rotl(uint64_t x,int o){return (x<<o)|(x>>(64-o));}
static const uint64_t hRC[24]={
  0x0000000000000001ULL,0x0000000000008082ULL,0x800000000000808aULL,0x8000000080008000ULL,
  0x000000000000808bULL,0x0000000080000001ULL,0x8000000080008081ULL,0x8000000000008009ULL,
  0x000000000000008aULL,0x0000000000000088ULL,0x0000000080008009ULL,0x000000008000000aULL,
  0x000000008000808bULL,0x800000000000008bULL,0x8000000000008089ULL,0x8000000000008003ULL,
  0x8000000000008002ULL,0x8000000000000080ULL,0x000000000000800aULL,0x800000008000000aULL,
  0x8000000080008081ULL,0x8000000000008080ULL,0x0000000080000001ULL,0x8000000080008008ULL};
static void hkeccakf(uint64_t st[25]){
  const int piln[24]={10,7,11,17,18,3,5,16,8,21,24,4,15,23,19,13,12,2,20,14,22,9,6,1};
  const int rho[24]={1,3,6,10,15,21,28,36,45,55,2,14,27,41,56,8,25,43,62,18,39,61,20,44};
  for(int r=0;r<24;r++){
    uint64_t bc[5],t;
    for(int i=0;i<5;i++) bc[i]=st[i]^st[i+5]^st[i+10]^st[i+15]^st[i+20];
    for(int i=0;i<5;i++){ t=bc[(i+4)%5]^rotl(bc[(i+1)%5],1); for(int j=0;j<25;j+=5) st[j+i]^=t; }
    t=st[1];
    for(int i=0;i<24;i++){ int j=piln[i]; uint64_t b=st[j]; st[j]=rotl(t,rho[i]); t=b; }
    for(int j=0;j<25;j+=5){ uint64_t a[5]; for(int i=0;i<5;i++)a[i]=st[j+i];
      for(int i=0;i<5;i++) st[j+i]=a[i]^((~a[(i+1)%5])&a[(i+2)%5]); }
    st[0]^=hRC[r];
  }
}
static void keccak256(const uint8_t* msg,size_t len,uint8_t out[32]){
  uint64_t st[25]; memset(st,0,sizeof(st));
  uint8_t block[136]; size_t i=0;
  while(len-i>=136){
    for(int k=0;k<17;k++){ uint64_t l=0; for(int b=0;b<8;b++) l|=((uint64_t)msg[i+k*8+b])<<(8*b); st[k]^=l; }
    hkeccakf(st); i+=136;
  }
  size_t rem=len-i; memset(block,0,136); memcpy(block,msg+i,rem);
  block[rem]^=0x01; block[135]^=0x80;
  for(int k=0;k<17;k++){ uint64_t l=0; for(int b=0;b<8;b++) l|=((uint64_t)block[k*8+b])<<(8*b); st[k]^=l; }
  hkeccakf(st);
  for(int k=0;k<4;k++) for(int b=0;b<8;b++) out[k*8+b]=(uint8_t)(st[k]>>(8*b));
}
static int hexval(char c){ if(c>='0'&&c<='9')return c-'0'; if(c>='a'&&c<='f')return c-'a'+10; if(c>='A'&&c<='F')return c-'A'+10; return -1; }
static size_t hexdecode(const char* h,uint8_t* out){
  if(h[0]=='0'&&(h[1]=='x'||h[1]=='X')) h+=2;
  size_t n=0; while(h[0]&&h[1]){ int hi=hexval(h[0]),lo=hexval(h[1]); if(hi<0||lo<0)break; out[n++]=(uint8_t)((hi<<4)|lo); h+=2; } return n;
}

#define CK(x) do{ cudaError_t e=(x); if(e!=cudaSuccess){ fprintf(stderr,"CUDA err %s:%d %s\n",__FILE__,__LINE__,cudaGetErrorString(e)); exit(2);} }while(0)

int main(int argc,char**argv){
  if(argc<3){ fprintf(stderr,"usage: %s <initcode_hex_file> <base24_hex> [startCounter]\n",argv[0]); return 1; }
  FILE* f=fopen(argv[1],"r"); if(!f){perror("open");return 1;}
  static char hexbuf[1<<16]; size_t hn=fread(hexbuf,1,sizeof(hexbuf)-1,f); hexbuf[hn]=0; fclose(f);
  while(hn>0 && (hexbuf[hn-1]=='\n'||hexbuf[hn-1]=='\r'||hexbuf[hn-1]==' '||hexbuf[hn-1]=='\t')) hexbuf[--hn]=0;
  static uint8_t initcode[1<<15]; size_t iclen=hexdecode(hexbuf,initcode);
  uint8_t ich[32]; keccak256(initcode,iclen,ich);
  fprintf(stderr,"initcode len=%zu keccak256(initcode)=0x",iclen);
  for(int i=0;i<32;i++) fprintf(stderr,"%02x",ich[i]); fprintf(stderr,"\n");

  uint8_t base24[24]; memset(base24,0,24); hexdecode(argv[2],base24);
  uint64_t startCounter = (argc>3)? strtoull(argv[3],0,0) : 0;

  const uint8_t FACTORY[20]={0x4e,0x59,0xb4,0x48,0x47,0xb3,0x79,0x57,0x85,0x88,0x92,0x0c,0xA7,0x8F,0xbF,0x26,0xc0,0xB4,0x95,0x6C};
  uint8_t pre[85]; memset(pre,0,85);
  pre[0]=0xff; memcpy(pre+1,FACTORY,20); memcpy(pre+21,base24,24); memcpy(pre+53,ich,32);
  // print base salt (bytes 21..45 = base24, 45..53 = counter placeholder)
  fprintf(stderr,"base24=0x"); for(int i=0;i<24;i++) fprintf(stderr,"%02x",base24[i]); fprintf(stderr,"\n");

  uint64_t fullBase[17]; memset(fullBase,0,sizeof(fullBase));
  for(int k=0;k<17;k++){ uint64_t l=0; for(int b=0;b<8;b++){ size_t idx=k*8+b; uint8_t v=(idx<85)?pre[idx]:0; l|=((uint64_t)v)<<(8*b);} fullBase[k]=l; }
  fullBase[10] |= ((uint64_t)0x01)<<(8*5); // byte85 pad start
  fullBase[16] |= ((uint64_t)0x80)<<(8*7); // byte135 pad end
  CK(cudaMemcpyToSymbol(d_base,fullBase,sizeof(fullBase)));

  // Optional self-test: `miner <ic> <base24> dump <counter>` prints device keccak output.
  if(argc>4 && strcmp(argv[3],"dump")==0){
    uint64_t dc=strtoull(argv[4],0,0);
    uint8_t *d_out; CK(cudaMalloc(&d_out,32));
    dumpKernel<<<1,1>>>(dc,d_out); CK(cudaGetLastError()); CK(cudaDeviceSynchronize());
    uint8_t out[32]; CK(cudaMemcpy(out,d_out,32,cudaMemcpyDeviceToHost));
    uint8_t salt[32]; memcpy(salt,base24,24);
    salt[24]=(uint8_t)(dc>>56);salt[25]=(uint8_t)(dc>>48);salt[26]=(uint8_t)(dc>>40);salt[27]=(uint8_t)(dc>>32);
    salt[28]=(uint8_t)(dc>>24);salt[29]=(uint8_t)(dc>>16);salt[30]=(uint8_t)(dc>>8);salt[31]=(uint8_t)(dc);
    printf("DUMP counter=%llu\n",(unsigned long long)dc);
    printf("SALT=0x"); for(int i=0;i<32;i++) printf("%02x",salt[i]); printf("\n");
    printf("GPU_KECCAK=0x"); for(int i=0;i<32;i++) printf("%02x",out[i]); printf("\n");
    printf("GPU_ADDR=0x"); for(int i=12;i<32;i++) printf("%02x",out[i]); printf("\n");
    return 0;
  }

  unsigned long long *d_fc; int *d_ff;
  CK(cudaMalloc(&d_fc,sizeof(unsigned long long)));
  CK(cudaMalloc(&d_ff,sizeof(int)));
  CK(cudaMemset(d_ff,0,sizeof(int)));

  // Match config via env: B17 (hex byte, default 0x00), B16LOWZERO (0/1, default 0).
  unsigned int b17 = 0x00; { const char* e=getenv("B17"); if(e) b17=(unsigned int)strtoul(e,0,16); }
  int b16low = 0; { const char* e=getenv("B16LOWZERO"); if(e) b16low=atoi(e); }
  fprintf(stderr,"match: prefix=0x0000 b16low=%d b17=0x%02x suffix=..%02x8282\n",b16low,b17,b17);

  const int TPB=256;
  const uint64_t BATCH = (uint64_t)1<<28; // ~268M per launch
  uint64_t counter=startCounter;
  double totalHashes=0;
  cudaEvent_t t0,t1; cudaEventCreate(&t0); cudaEventCreate(&t1);
  for(;;){
    long long blocks=(BATCH+TPB-1)/TPB;
    cudaEventRecord(t0);
    mineKernel<<<blocks,TPB>>>(counter,BATCH,b16low,b17,d_fc,d_ff);
    cudaEventRecord(t1); CK(cudaGetLastError());
    CK(cudaEventSynchronize(t1));
    int ff; CK(cudaMemcpy(&ff,d_ff,sizeof(int),cudaMemcpyDeviceToHost));
    float ms=0; cudaEventElapsedTime(&ms,t0,t1);
    totalHashes+=(double)BATCH;
    if(ff){
      unsigned long long fc; CK(cudaMemcpy(&fc,d_fc,sizeof(fc),cudaMemcpyDeviceToHost));
      // rebuild full salt = base24 ++ counter(BE 8 bytes)
      uint8_t salt[32]; memcpy(salt,base24,24);
      salt[24]=(uint8_t)(fc>>56);salt[25]=(uint8_t)(fc>>48);salt[26]=(uint8_t)(fc>>40);salt[27]=(uint8_t)(fc>>32);
      salt[28]=(uint8_t)(fc>>24);salt[29]=(uint8_t)(fc>>16);salt[30]=(uint8_t)(fc>>8);salt[31]=(uint8_t)(fc);
      // verify on host
      uint8_t vpre[85]; memcpy(vpre,pre,85); memcpy(vpre+21,salt,32);
      uint8_t vout[32]; keccak256(vpre,85,vout);
      printf("FOUND counter=%llu\n",fc);
      printf("SALT=0x"); for(int i=0;i<32;i++) printf("%02x",salt[i]); printf("\n");
      printf("ADDR=0x"); for(int i=12;i<32;i++) printf("%02x",vout[i]); printf("\n");
      fflush(stdout);
      break;
    }
    counter+=BATCH;
    fprintf(stderr,"batch done, counter=%llu, %.1f MH/s, total=%.3g\n",
            (unsigned long long)counter,(BATCH/1e6)/(ms/1000.0),totalHashes);
  }
  return 0;
}
