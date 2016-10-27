// Blake2-B CUDA Implementation
// tpruvot@github July 2016
// permission granted to use under MIT license
// modified for use in Zcash by John Tromp September 2016

/**
 * uint2 direct ops by c++ operator definitions
 */

// static __device__ __forceinline__ uint2 operator^ (uint2 a, uint2 b) {
//   return make_uint2(a.x ^ b.x, a.y ^ b.y);
// }

// uint2 ROR/ROL methods
uint2 ROR2(const uint2 a, const int offset) {
  uint2 result;
  if (!offset)
          result = a;
  else if (offset < 32) {
          result.y = ((a.y >> offset) | (a.x << (32 - offset)));
          result.x = ((a.x >> offset) | (a.y << (32 - offset)));
  } else if (offset == 32) {
          result.y = a.x;
          result.x = a.y;
  } else {
          result.y = ((a.x >> (offset - 32)) | (a.y << (64 - offset)));
          result.x = ((a.y >> (offset - 32)) | (a.x << (64 - offset)));
  }
  return result;
}

uint2 SWAPUINT2(uint2 value) {
  uint2 result;
  result.x = value.y;
  result.y = value.x;
  return result;
}

#define ROR24(u) ROR2(u,24)
#define ROR16(u) ROR2(u,16)

__constant int8_t blake2b_sigma[12][16] = {
  { 0,  1,  2,  3,  4,  5,  6,  7,  8,  9,  10, 11, 12, 13, 14, 15 } ,
  { 14, 10, 4,  8,  9,  15, 13, 6,  1,  12, 0,  2,  11, 7,  5,  3  } ,
  { 11, 8,  12, 0,  5,  2,  15, 13, 10, 14, 3,  6,  7,  1,  9,  4  } ,
  { 7,  9,  3,  1,  13, 12, 11, 14, 2,  6,  5,  10, 4,  0,  15, 8  } ,
  { 9,  0,  5,  7,  2,  4,  10, 15, 14, 1,  11, 12, 6,  8,  3,  13 } ,
  { 2,  12, 6,  10, 0,  11, 8,  3,  4,  13, 7,  5,  15, 14, 1,  9  } ,
  { 12, 5,  1,  15, 14, 13, 4,  10, 0,  7,  6,  3,  9,  2,  8,  11 } ,
  { 13, 11, 7,  14, 12, 1,  3,  9,  5,  0,  15, 4,  8,  6,  2,  10 } ,
  { 6,  15, 14, 9,  11, 3,  0,  8,  12, 2,  13, 7,  1,  4,  10, 5  } ,
  { 10, 2,  8,  4,  7,  6,  1,  5,  15, 11, 9,  14, 3,  12, 13, 0  } ,
  { 0,  1,  2,  3,  4,  5,  6,  7,  8,  9,  10, 11, 12, 13, 14, 15 } ,
  { 14, 10, 4,  8,  9,  15, 13, 6,  1,  12, 0,  2,  11, 7,  5,  3  }
};

void G(const int32_t r, const int32_t i, uint64_t *a, uint64_t *b, uint64_t *c, uint64_t *d, uint64_t const m[16]) {
  *a += *b + m[ blake2b_sigma[r][2*i] ];
  ((uint2*)d)[0] = SWAPUINT2( ((uint2*)d)[0] ^ ((uint2*)a)[0] );
  *c += *d;
  ((uint2*)b)[0] = ROR24( ((uint2*)b)[0] ^ ((uint2*)c)[0] );
  *a += *b + m[ blake2b_sigma[r][2*i+1] ];
  ((uint2*)d)[0] = ROR16( ((uint2*)d)[0] ^ ((uint2*)a)[0] );
  *c += *d;
  ((uint2*)b)[0] = ROR2( ((uint2*)b)[0] ^ ((uint2*)c)[0], 63U);
}

#define ROUND(r) \
  G(r, 0, &v[0], &v[4], &v[ 8], &v[12], m); \
  G(r, 1, &v[1], &v[5], &v[ 9], &v[13], m); \
  G(r, 2, &v[2], &v[6], &v[10], &v[14], m); \
  G(r, 3, &v[3], &v[7], &v[11], &v[15], m); \
  G(r, 4, &v[0], &v[5], &v[10], &v[15], m); \
  G(r, 5, &v[1], &v[6], &v[11], &v[12], m); \
  G(r, 6, &v[2], &v[7], &v[ 8], &v[13], m); \
  G(r, 7, &v[3], &v[4], &v[ 9], &v[14], m);

#define TOTAL_BLAKE2B_EQUI_COUNTER (128+16)  
  
void blake2b_equi(uint64_t d0,
                  uint64_t d1,
                  uint64_t d2,
                  uint64_t d3,
                  uint64_t d4,
                  uint64_t d5,
                  uint64_t d6,
                  uint64_t d7,
                  uint32_t buff0,
                  uint32_t buff1,
                  uint32_t buff2,
                  uint32_t idx,
                  uint64_t *out)
{
  
  uint64_t m[16];
  m[0] = (((uint64_t)buff1) << 32) | buff0;
  m[1] = (((uint64_t)idx) << 32) | buff2;
  m[2] = 0;
  m[3] = 0;
  m[4] = 0;
  m[5] = 0;
  m[6] = 0;
  m[7] = 0;
  m[8] = 0;
  m[9] = 0;
  m[10] = 0;
  m[11] = 0;  
  m[12] = 0;
  m[13] = 0;
  m[14] = 0;
  m[15] = 0;    
  
  uint64_t v[16];
  v[0] = d0;
  v[1] = d1;
  v[2] = d2;
  v[3] = d3;
  v[4] = d4;
  v[5] = d5;
  v[6] = d6;
  v[7] = d7;
  v[8] = 0x6a09e667f3bcc908;
  v[9] = 0xbb67ae8584caa73b;
  v[10] =  0x3c6ef372fe94f82b;
  v[11] = 0xa54ff53a5f1d36f1;
  v[12] = 0x510e527fade682d1 ^ TOTAL_BLAKE2B_EQUI_COUNTER;
  v[13] = 0x9b05688c2b3e6c1f;
  v[14] = 0x1f83d9abfb41bd6b ^ 0xffffffffffffffff;
  v[15] = 0x5be0cd19137e2179;
  
  ROUND( 0 );
  ROUND( 1 );
  ROUND( 2 );
  ROUND( 3 );
  ROUND( 4 );
  ROUND( 5 );
  ROUND( 6 );
  ROUND( 7 );
  ROUND( 8 );
  ROUND( 9 );
  ROUND( 10 );
  ROUND( 11 );
  
  out[0] = d0 ^ v[0] ^ v[ 8];
  out[1] = d1 ^ v[1] ^ v[ 9];
  out[2] = d2 ^ v[2] ^ v[10];
  out[3] = d3 ^ v[3] ^ v[11];
  out[4] = d4 ^ v[4] ^ v[12];
  out[5] = d5 ^ v[5] ^ v[13];
  out[6] = d6 ^ v[6] ^ v[14];
  out[7] = d7 ^ v[7] ^ v[15];
}
