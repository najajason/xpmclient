#include "common.h"

#include "blake2bcl.h"

#define tree0_ptr(heap, r) ((__global bucket0 *)(heap + r))
#define tree1_ptr(heap, r) ((__global bucket1 *)(heap + r))

uint32_t tree_bucket(tree t)
{
  const uint32_t bucketMask = ((1u<<BUCKBITS)-1);
  return t & bucketMask;
}
;
uint32_t tree_slotid0(tree t)
{
  const uint32_t slotMask =  ((1u<<SLOTBITS)-1);
  return (t >> BUCKBITS) & SLOTMASK;
}

uint32_t tree_slotid1(tree t)
{
  const uint32_t slotMask =  ((1u<<SLOTBITS)-1);
  return (t >> (BUCKBITS+SLOTBITS)) & SLOTMASK;
}

uint32_t tree_xhash(tree t)
{
  return t >> (2*SLOTBITS + BUCKBITS);
}

uint32_t tree_getindex(const tree t)
{
  const uint32_t bucketMask = ((1u<<BUCKBITS)-1);
  const uint32_t slotMask =  ((1u<<SLOTBITS)-1);
  return ((t & bucketMask) << SLOTBITS) | ((t & (slotMask << BUCKBITS)) >> BUCKBITS);  
}

void tree_setindex(tree *t, uint32_t idx)
{
  const uint32_t bucketMask = ((1u<<BUCKBITS)-1);
  const uint32_t slotMask =  ((1u<<SLOTBITS)-1);

  (*t) &= ~(bucketMask | (slotMask << BUCKBITS));
  (*t) |= (idx >> SLOTBITS);
  (*t) |= ((idx & slotMask) << BUCKBITS);
}

void tree_setxhash(tree *t, uint32_t xhash)
{
  const uint32_t xhashMask = ((1u << RESTBITS)-1);
  (*t) &= ~(xhashMask << (2*SLOTBITS + BUCKBITS));
  (*t) |= (xhash << (2*SLOTBITS + BUCKBITS));
}

tree tree_create3(uint32_t bucketId, uint32_t s0, uint32_t s1)
{
  return bucketId | (s0 << BUCKBITS) | (s1 << (BUCKBITS+SLOTBITS));
}

tree tree_create4(uint32_t bucketId, uint32_t s0, uint32_t s1, uint32_t xhash)
{
  return bucketId | (s0 << BUCKBITS) | (s1 << (BUCKBITS+SLOTBITS)) | (xhash << (2*SLOTBITS+BUCKBITS));;
}

// size (in bytes) of hash in round 0 <= r < WK
#ifdef XINTREE
#define HASHSIZE(r) (((WN - (r+1) * DIGITBITS)+7)/8)
#else
#define HASHSIZE(r) (((WN - (r+1) * DIGITBITS + RESTBITS)+7)/8)
#endif

uint32_t hashwords(uint32_t bytes)
{
  return (bytes + 3) / 4;
}

htlayout htlayout_create_2(uint32_t r)
{
  htlayout R;
  R.prevhashunits = 0;
  R.dunits = 0;
  
  uint32_t nexthashbytes = HASHSIZE(r);
  R.nexthashunits = hashwords(nexthashbytes);
  
  R.prevbo = 0;
  R.nextbo = R.nexthashunits * sizeof(hashunit) - nexthashbytes; // 0-3
  if (r) {
    uint32_t prevhashbytes = HASHSIZE(r-1);
    R.prevhashunits = hashwords(prevhashbytes);
    R.prevbo = R.prevhashunits * sizeof(hashunit) - prevhashbytes; // 0-3
    R.dunits = R.prevhashunits - R.nexthashunits;
  }
  
  return R;
}

uint32_t htlayout_getxhash0(uint32_t prevbo, __global const slot0 *pslot)
{
#ifdef XINTREE
  return tree_xhash(pslot->attr);
#elif WN == 200 && RESTBITS == 4
  return pslot->hash->bytes[prevbo] >> 4;
#elif WN == 200 && RESTBITS == 8
  return (pslot->hash->bytes[prevbo] & 0xf) << 4 | pslot->hash->bytes[prevbo+1] >> 4;
#elif WN == 144 && RESTBITS == 4
  return pslot->hash->bytes[prevbo] & 0xf;
#elif WN == 200 && RESTBITS == 6
  return (pslot->hash->bytes[prevbo] & 0x3) << 4 | pslot->hash->bytes[prevbo+1] >> 4;
#else
#error non implemented
#endif
}

uint32_t htlayout_getxhash1(uint32_t prevbo, __global const slot1 *pslot)
{
#ifdef XINTREE
  return tree_xhash(pslot->attr);
#elif WN == 200 && RESTBITS == 4
  return pslot->hash->bytes[prevbo] & 0xf;
#elif WN == 200 && RESTBITS == 8
  return pslot->hash->bytes[prevbo];
#elif WN == 144 && RESTBITS == 4
  return pslot->hash->bytes[prevbo] & 0xf;
#elif WN == 200 && RESTBITS == 6
  return pslot->hash->bytes[prevbo] & 0x3f;
#else
#error non implemented
#endif  
}

bool htlayout_equal(uint32_t prevhashunits, __global const hashunit *hash0, __global const hashunit *hash1)
{
  return hash0[prevhashunits-1].word == hash1[prevhashunits-1].word;
}

void collisiondata_clear(collisiondata *data) 
{
#ifdef XBITMAP
  // memset(xhashmap, 0, NRESTS * sizeof(u64));
  for (unsigned i = 0; i < NRESTS; i++)
    data->xhashmap[i] = 0;
#else
  // memset(nxhashslots, 0, NRESTS * sizeof(xslot));
  for (unsigned i = 0; i < NRESTS; i++)
    data->nxhashslots[i] = 0;
#endif
}

bool collisiondata_addslot(collisiondata *data, uint32_t s1, uint32_t xh)
{
#ifdef XBITMAP
  data->xmap = data->xhashmap[xh];
  data->xhashmap[xh] |= (uint64_t)1 << s1;
  data->s0 = ~0;
  return true;
#else
  data->n1 = (uint32_t)data->nxhashslots[xh]++;
  if (data->n1 >= XFULL)
    return false;
  data->xx = data->xhashslots[xh];
  data->xx[data->n1] = s1;
  data->n0 = 0;
  return true;
#endif
}

bool collisiondata_nextcollision(collisiondata *data)
{
#ifdef XBITMAP
  return data->xmap != 0;
#else
  return data->n0 < data->n1;
#endif
}

uint64_t __ffsll(uint64_t x)
{
  return x ? (64 - clz(x & -x)) : 0;
}

uint32_t collisiondata_slot(collisiondata *data) {
#ifdef XBITMAP
  const uint32_t ffs = __ffsll(xmap);
  data->s0 += ffs;
  data->xmap >>= ffs;
  return data->s0;
#else
  return (uint32_t)data->xx[data->n0++];
#endif
}

uint32_t equi_getnslots(__global bsizes *nslots, const uint32_t r, const uint32_t bid)
{
  __global uint32_t *nslot = &nslots[r&1][bid];
  const uint32_t n = min(*nslot, NSLOTS);
  *nslot = 0;
  return n;
}

void orderindices(uint32_t *indices, uint32_t size)
{
  if (indices[0] > indices[size]) {
    for (uint32_t i = 0; i < size; i++) {
      const uint32_t tmp = indices[i];
      indices[i] = indices[size+i];
      indices[size+i] = tmp;
    }
  }
}


void listindices1(__global uint32_t *heap0,
                       __global uint32_t *heap1,
                       const tree t,
                       uint32_t *indices)
{
  const __global bucket0 *buck = &tree0_ptr(heap0, 0)[tree_bucket(t)];
  const uint32_t size = 1 << 0;
  
  uint32_t i0 = tree_getindex((*buck)[tree_slotid0(t)].attr);
  uint32_t i1 = tree_getindex((*buck)[tree_slotid1(t)].attr);
  uint32_t offset = i0 > i1 ? 1 : 0;
  indices[offset] = i0;
  indices[offset^1] = i1;
}

void listindices2(__global uint32_t *heap0,
                       __global uint32_t *heap1,
                       const tree t,
                       uint32_t *indices)
{
  const __global bucket1 *buck = &tree1_ptr(heap1, 0)[tree_bucket(t)];
  const uint32_t size = 1 << 1;
  listindices1(heap0, heap1, (*buck)[tree_slotid0(t)].attr, indices);
  listindices1(heap0, heap1, (*buck)[tree_slotid1(t)].attr, indices+size);
  orderindices(indices, size);
}

void listindices3(__global uint32_t *heap0,
                       __global uint32_t *heap1,
                       const tree t,
                       uint32_t *indices)
{
  const __global bucket0 *buck = &tree0_ptr(heap0, 1)[tree_bucket(t)];
  const uint32_t size = 1 << 2;
  listindices2(heap0, heap1, (*buck)[tree_slotid0(t)].attr, indices);
  listindices2(heap0, heap1, (*buck)[tree_slotid1(t)].attr, indices+size);
  orderindices(indices, size);
}

void listindices4(__global uint32_t *heap0,
                       __global uint32_t *heap1,
                       const tree t,
                       uint32_t *indices)
{
  const __global bucket1 *buck = &tree1_ptr(heap1, 1)[tree_bucket(t)];
  const uint32_t size = 1 << 3;
  listindices3(heap0, heap1, (*buck)[tree_slotid0(t)].attr, indices);
  listindices3(heap0, heap1, (*buck)[tree_slotid1(t)].attr, indices+size);
  orderindices(indices, size);
}
 
void listindices5(__global uint32_t *heap0,
                       __global uint32_t *heap1,
                       const tree t,
                       uint32_t *indices)
{
  const __global bucket0 *buck = &tree0_ptr(heap0, 2)[tree_bucket(t)];
  const uint32_t size = 1 << 4;
  listindices4(heap0, heap1, (*buck)[tree_slotid0(t)].attr, indices);
  listindices4(heap0, heap1, (*buck)[tree_slotid1(t)].attr, indices+size);
  orderindices(indices, size);
}  
  
void listindices6(__global uint32_t *heap0,
                       __global uint32_t *heap1,
                       const tree t,
                       uint32_t *indices)
{
  const __global bucket1 *buck = &tree1_ptr(heap1, 2)[tree_bucket(t)];
  const uint32_t size = 1 << 5;
  listindices5(heap0, heap1, (*buck)[tree_slotid0(t)].attr, indices);
  listindices5(heap0, heap1, (*buck)[tree_slotid1(t)].attr, indices+size);
  orderindices(indices, size);
}  
  
void listindices7(__global uint32_t *heap0,
                       __global uint32_t *heap1,
                       const tree t,
                       uint32_t *indices)
{
  const __global bucket0 *buck = &tree0_ptr(heap0, 3)[tree_bucket(t)];
  const uint32_t size = 1 << 6;
  listindices6(heap0, heap1, (*buck)[tree_slotid0(t)].attr, indices);
  listindices6(heap0, heap1, (*buck)[tree_slotid1(t)].attr, indices+size);
  orderindices(indices, size);
}  

void listindices8(__global uint32_t *heap0,
                       __global uint32_t *heap1,
                       const tree t,
                       uint32_t *indices)
{
  const __global bucket1 *buck = &tree1_ptr(heap1, 3)[tree_bucket(t)];
  const uint32_t size = 1 << 7;
  listindices7(heap0, heap1, (*buck)[tree_slotid0(t)].attr, indices);
  listindices7(heap0, heap1, (*buck)[tree_slotid1(t)].attr, indices+size);
  orderindices(indices, size);
}  

void listindices9(__global uint32_t *heap0,
                       __global uint32_t *heap1,
                       const tree t,
                       uint32_t *indices)
{
  const __global bucket0 *buck = &tree0_ptr(heap0, 4)[tree_bucket(t)];
  const uint32_t size = 1 << 8;
  listindices8(heap0, heap1, (*buck)[tree_slotid0(t)].attr, indices);
  listindices8(heap0, heap1, (*buck)[tree_slotid1(t)].attr, indices+size);
  orderindices(indices, size);
}


// proper dupe test is a little costly on GPU, so allow false negatives
bool equi_probdupe(uint32_t *prf) {
  unsigned short susp[PROOFSIZE];
  for (unsigned i = 0; i < PROOFSIZE; i++)
    susp[i] = 0xFFFF;
    
  for (unsigned i = 0; i < PROOFSIZE; i++) {
    uint32_t data = prf[i];
    uint32_t bin = data & (PROOFSIZE-1);
    unsigned short msb = data >> WK;
    if (msb == susp[bin])
      return true;
    susp[bin] = msb;
  }
  
  return false;
}



void equi_candidate(__global uint32_t *heap0,
                    __global uint32_t *heap1,
                    __global proof *sols,
                    __global uint32_t *nsols,
                    const tree t)
{
  proof prf;

#if WK==9
  listindices9(heap0, heap1, t, (uint32_t*)prf);
#elif WK==5
  listindices5(heap0, heap1, t, (uint32_t*)prf);
#else
#error not implemented
#endif
  if (equi_probdupe(prf))  
    return;
  uint32_t soli = atomic_inc(nsols);
  if (soli < MAXSOLS) {
    for (unsigned i = 0; i < sizeof(proof)/4; i++)
      sols[soli][i] = prf[i];
  }
}


uint32_t extract_byte_from_ui32_array(uint32_t *array, unsigned offset)
{
  uint32_t R = array[offset/4] >> (8*(offset%4));
  return (offset%4 == 3) ?
    R : R & 0xFF;
}  

__kernel void digitH(__global const uint32_t *heap0,
                     __global bsizes *nslots,
                     uint64_t d0,
                     uint64_t d1,
                     uint64_t d2,
                     uint64_t d3,
                     uint64_t d4,
                     uint64_t d5,
                     uint64_t d6,
                     uint64_t d7,
                     uint32_t buff0,
                     uint32_t buff1,
                     uint32_t buff2)
{
  uint32_t hash[16];
  htlayout htl = htlayout_create_2(0);
  for (uint32_t block = get_global_id(0); block < NBLOCKS; block += get_global_size(0)) {
    // do blake2b, no global memory used
    blake2b_equi(d0, d1, d2, d3, d4, d5, d6, d7, buff0, buff1, buff2, block, (uint64_t*)hash);
#pragma unroll
    for (unsigned i = 0; i < HASHESPERBLAKE; i++) { // default: 2 rounds
      const unsigned phOffset = i*WN/8; // default: [0, 25]
      const uint32_t ph0 = extract_byte_from_ui32_array(hash, phOffset+0);
      const uint32_t ph1 = extract_byte_from_ui32_array(hash, phOffset+1);
      const uint32_t ph2 = extract_byte_from_ui32_array(hash, phOffset+2);   
      
#if BUCKBITS == 16 && RESTBITS == 4
      const uint32_t bucketid = (ph0 << 8) | ph1;
#ifdef XINTREE
      const uint32_t xhash = ph2 >> 4;
#endif
#elif BUCKBITS == 14 && RESTBITS == 6
      const uint32_t bucketid = (ph0 << 6) | (ph1 >> 2);
#elif BUCKBITS == 12 && RESTBITS == 8
      const uint32_t bucketid = (ph0 << 4) | ph1 >> 4;
#elif BUCKBITS == 20 && RESTBITS == 4
      const uint32_t bucketid = (((ph0 << 8) | ph1) << 4) | ph2 >> 4;
#ifdef XINTREE
      const uint32_t xhash = ph2 & 0xf;
#endif
#elif BUCKBITS == 12 && RESTBITS == 4
      const uint32_t bucketid = (ph0 << 4) | (ph1 >> 4);
      const uint32_t xhash = ph1 & 0xf;
#else
#error not implemented
#endif      
      
      const uint32_t slot = atomic_inc(&nslots[0][bucketid]);
      if (slot >= NSLOTS)
        continue;
      tree leaf;
      tree_setindex(&leaf, block*HASHESPERBLAKE+i);
#ifdef XINTREE
      tree_setxhash(&leaf, xhash);
#endif
     
      __global slot0 *s = &tree0_ptr(heap0, 0)[bucketid][slot];
      __global uint8_t *dst8 = ((__global uint8_t*)s->hash->bytes+htl.nextbo);
      const uint32_t hashBytes = HASHSIZE(0);
      s->attr = leaf;
      for (unsigned i = 0; i < hashBytes; i++)
        dst8[i] = extract_byte_from_ui32_array(hash, phOffset+WN/8-hashBytes + i);
    }
  }
}

__kernel void digitOdd(const uint32_t r,
                       __global uint32_t *heap0,
                       __global uint32_t *heap1,
                       __global bsizes *nslots)
{
  // equi::htlayout htl(eq, r);
//   htlayout htl = htlayout_create(eq, r);
  htlayout htl = htlayout_create_2(r);  
  collisiondata cd;
  
  // const uint32_t id = blockIdx.x * blockDim.x + threadIdx.x;
  const uint32_t id = get_global_id(0);
  
  for (uint32_t bucketid = id; bucketid < NBUCKETS; bucketid += get_global_size(0)) {
    // cd.clear();
    collisiondata_clear(&cd);
//     __global slot0 *buck = htl.hta.trees0[(r-1)/2][bucketid]; // optimize by updating previous buck?!
    __global slot0 *buck = tree0_ptr(heap0, (r-1)/2)[bucketid]; // optimize by updating previous buck?!    
    uint32_t bsize = equi_getnslots(nslots, r-1, bucketid);       // optimize by putting bucketsize with block?!
    for (uint32_t s1 = 0; s1 < bsize; s1++) {
      __global const slot0 *pslot1 = buck + s1;          // optimize by updating previous pslot1?!
      if (!collisiondata_addslot(&cd, s1, htlayout_getxhash0(htl.prevbo, pslot1)))
        continue;
      for (; collisiondata_nextcollision(&cd); ) {
        const uint32_t s0 = collisiondata_slot(&cd);
        __global const slot0 *pslot0 = buck + s0;
        if (htlayout_equal(htl.prevhashunits, pslot0->hash, pslot1->hash))
          continue;
        uint32_t xorbucketid;
        uint32_t xhash;
        __global const uint8_t *bytes0 = pslot0->hash->bytes, *bytes1 = pslot1->hash->bytes;
#if WN == 200 && BUCKBITS == 16 && RESTBITS == 4 && defined(XINTREE)
        xorbucketid = ((((uint32_t)(bytes0[htl.prevbo] ^ bytes1[htl.prevbo]) & 0xf) << 8)
                          | (bytes0[htl.prevbo+1] ^ bytes1[htl.prevbo+1])) << 4
                  | (xhash = bytes0[htl.prevbo+2] ^ bytes1[htl.prevbo+2]) >> 4;
        xhash &= 0xf;
#elif WN == 144 && BUCKBITS == 20 && RESTBITS == 4
        xorbucketid = ((((uint32_t)(bytes0[htl.prevbo+1] ^ bytes1[htl.prevbo+1]) << 8)
                            | (bytes0[htl.prevbo+2] ^ bytes1[htl.prevbo+2])) << 4)
                    | (xhash = bytes0[htl.prevbo+3] ^ bytes1[htl.prevbo+3]) >> 4;
        xhash &= 0xf;
#elif WN == 96 && BUCKBITS == 12 && RESTBITS == 4
        xorbucketid = ((uint32_t)(bytes0[htl.prevbo+1] ^ bytes1[htl.prevbo+1]) << 4)
                  | (xhash = bytes0[htl.prevbo+2] ^ bytes1[htl.prevbo+2]) >> 4;
        xhash &= 0xf;
#elif WN == 200 && BUCKBITS == 14 && RESTBITS == 6
        xorbucketid = ((((uint32_t)(bytes0[htl.prevbo+1] ^ bytes1[htl.prevbo+1]) & 0xf) << 8)
                           | (bytes0[htl.prevbo+2] ^ bytes1[htl.prevbo+2])) << 2
                           | (bytes0[htl.prevbo+3] ^ bytes1[htl.prevbo+3]) >> 6;
#else
#error not implemented
#endif
        const uint32_t xorslot = atomic_inc(&nslots[1][xorbucketid]);
        if (xorslot >= NSLOTS)
          continue;
#ifdef XINTREE
        tree xort = tree_create4(bucketid, s0, s1, xhash);
#else
        tree xort = tree_create3(bucketid, s0, s1);
#endif
//         __global slot1 *xs = &htl.hta.trees1[r/2][xorbucketid][xorslot];
        __global slot1 *xs = &tree1_ptr(heap1, r/2)[xorbucketid][xorslot];        
        xs->attr = xort;
        for (uint32_t i = htl.dunits; i < htl.prevhashunits; i++)
          xs->hash[i-htl.dunits].word = pslot0->hash[i].word ^ pslot1->hash[i].word;
      }
    }
  }
}


__kernel void digitEven(const uint32_t r,
                        __global uint32_t *heap0,
                        __global uint32_t *heap1,
                        __global bsizes *nslots)
{
  // equi::htlayout htl(eq, r);
//   htlayout htl = htlayout_create(eq, r);
  htlayout htl = htlayout_create_2(r);
  collisiondata cd;
  
  // const uint32_t id = blockIdx.x * blockDim.x + threadIdx.x;
  const uint32_t id = get_global_id(0);
  
  for (uint32_t bucketid = id; bucketid < NBUCKETS; bucketid += get_global_size(0)) {
    // cd.clear();
    collisiondata_clear(&cd);    
//     __global slot1 *buck = htl.hta.trees1[(r-1)/2][bucketid]; // OPTIMIZE BY UPDATING PREVIOUS
     __global slot1 *buck = tree1_ptr(heap1, (r-1)/2)[bucketid]; // OPTIMIZE BY UPDATING PREVIOUS
    uint32_t bsize = equi_getnslots(nslots, r-1, bucketid);
    for (uint32_t s1 = 0; s1 < bsize; s1++) {
      __global const slot1 *pslot1 = buck + s1;          // OPTIMIZE BY UPDATING PREVIOUS
      if (!collisiondata_addslot(&cd, s1, htlayout_getxhash1(htl.prevbo, pslot1)))
        continue;
      for (; collisiondata_nextcollision(&cd); ) {
        const uint32_t s0 = collisiondata_slot(&cd);
        __global const slot1 *pslot0 = buck + s0;
        if (htlayout_equal(htl.prevhashunits, pslot0->hash, pslot1->hash))
          continue;
        uint32_t xorbucketid;
        uint32_t xhash;
        __global const uint8_t *bytes0 = pslot0->hash->bytes, *bytes1 = pslot1->hash->bytes;
#if WN == 200 && BUCKBITS == 16 && RESTBITS == 4 && defined(XINTREE)
        xorbucketid = ((uint32_t)(bytes0[htl.prevbo] ^ bytes1[htl.prevbo]) << 8)
                        | (bytes0[htl.prevbo+1] ^ bytes1[htl.prevbo+1]);
                  xhash = (bytes0[htl.prevbo+2] ^ bytes1[htl.prevbo+2]) >> 4;
#elif WN == 144 && BUCKBITS == 20 && RESTBITS == 4
        xorbucketid = ((((uint32_t)(bytes0[htl.prevbo+1] ^ bytes1[htl.prevbo+1]) << 8)
                            | (bytes0[htl.prevbo+2] ^ bytes1[htl.prevbo+2])) << 4)
                            | (bytes0[htl.prevbo+3] ^ bytes1[htl.prevbo+3]) >> 4;
#elif WN == 96 && BUCKBITS == 12 && RESTBITS == 4
        xorbucketid = ((uint32_t)(bytes0[htl.prevbo+1] ^ bytes1[htl.prevbo+1]) << 4)
                          | (bytes0[htl.prevbo+2] ^ bytes1[htl.prevbo+2]) >> 4;
#elif WN == 200 && BUCKBITS == 14 && RESTBITS == 6
        xorbucketid = ((uint32_t)(bytes0[htl.prevbo+1] ^ bytes1[htl.prevbo+1]) << 6)
                          | (bytes0[htl.prevbo+2] ^ bytes1[htl.prevbo+2]) >> 2;
#else
#error not implemented
#endif
        const uint32_t xorslot = atomic_inc(&nslots[0][xorbucketid]);
        if (xorslot >= NSLOTS)
          continue;
#ifdef XINTREE
        tree xort = tree_create4(bucketid, s0, s1, xhash);
#else
        tree xort = tree_create3(bucketid, s0, s1);
#endif
//         __global slot0 *xs = &htl.hta.trees0[r/2][xorbucketid][xorslot];
        __global slot0 *xs = &tree0_ptr(heap0, r/2)[xorbucketid][xorslot];        
        xs->attr = xort;
        for (uint32_t i=htl.dunits; i < htl.prevhashunits; i++)
          xs->hash[i-htl.dunits].word = pslot0->hash[i].word ^ pslot1->hash[i].word;
      }
    }
  }
}


#ifdef UNROLL

__kernel void digit_1(__global uint32_t *heap0,
                      __global uint32_t *heap1,
                      __global bsizes *nslots)
{
  htlayout htl = htlayout_create_2(1);
  collisiondata cd;
  const uint32_t id = get_global_id(0);
  
  for (uint32_t bucketid=id; bucketid < NBUCKETS; bucketid += get_global_size(0)) {
    collisiondata_clear(&cd); 
    __global slot0 *buck = tree0_ptr(heap0, 0)[bucketid];
    uint32_t bsize = equi_getnslots(nslots, 0, bucketid);
    for (uint32_t s1 = 0; s1 < bsize; s1++) {
      __global const slot0 *pslot1 = buck + s1;
      if (!collisiondata_addslot(&cd, s1, htlayout_getxhash0(htl.prevbo, pslot1)))
        continue;
      for (; collisiondata_nextcollision(&cd); ) {
        const uint32_t s0 = collisiondata_slot(&cd);
        __global const slot0 *pslot0 = buck + s0;
        if (htlayout_equal(htl.prevhashunits, pslot0->hash, pslot1->hash))
          continue;
        uint32_t xorbucketid;
        uint32_t xhash;
        __global const uint8_t *bytes0 = pslot0->hash->bytes, *bytes1 = pslot1->hash->bytes;
        xorbucketid = ((((uint32_t)(bytes0[htl.prevbo] ^ bytes1[htl.prevbo]) & 0xf) << 8)
                          | (bytes0[htl.prevbo+1] ^ bytes1[htl.prevbo+1])) << 4
                  | (xhash = bytes0[htl.prevbo+2] ^ bytes1[htl.prevbo+2]) >> 4;
        xhash &= 0xf;
        const uint32_t xorslot = atomic_inc(&nslots[1][xorbucketid]);
        if (xorslot >= NSLOTS)
          continue;
        tree xort = tree_create4(bucketid, s0, s1, xhash);
//         __global slot1 *xs = &htl.hta.trees1[0][xorbucketid][xorslot];
        __global slot1 *xs = &tree1_ptr(heap1, 0)[xorbucketid][xorslot];
        xs->attr = xort;
        xs->hash[0].word = pslot0->hash[1].word ^ pslot1->hash[1].word;
        xs->hash[1].word = pslot0->hash[2].word ^ pslot1->hash[2].word;
        xs->hash[2].word = pslot0->hash[3].word ^ pslot1->hash[3].word;
        xs->hash[3].word = pslot0->hash[4].word ^ pslot1->hash[4].word;
        xs->hash[4].word = pslot0->hash[5].word ^ pslot1->hash[5].word;
      }
    }
  }
}
__kernel void digit_2(__global uint32_t *heap0,
                      __global uint32_t *heap1,
                      __global bsizes *nslots) {
  htlayout htl = htlayout_create_2(2);
  collisiondata cd;
  const uint32_t id = get_global_id(0);
  for (uint32_t bucketid=id; bucketid < NBUCKETS; bucketid += get_global_size(0)) {
    collisiondata_clear(&cd); 
//     __global slot1 *buck = htl.hta.trees1[0][bucketid];
    __global slot1 *buck = tree1_ptr(heap1, 0)[bucketid];    
    uint32_t bsize = equi_getnslots(nslots, 1, bucketid);
    for (uint32_t s1 = 0; s1 < bsize; s1++) {
      __global const slot1 *pslot1 = buck + s1;
      if (!collisiondata_addslot(&cd, s1, htlayout_getxhash1(htl.prevbo, pslot1)))  
        continue;
      for (; collisiondata_nextcollision(&cd); ) {
        const uint32_t s0 = collisiondata_slot(&cd);
        __global const slot1 *pslot0 = buck + s0;
        if (htlayout_equal(htl.prevhashunits, pslot0->hash, pslot1->hash))
          continue;
        uint32_t xorbucketid;
        uint32_t xhash;
        __global const uint8_t *bytes0 = pslot0->hash->bytes, *bytes1 = pslot1->hash->bytes;
        xorbucketid = ((uint32_t)(bytes0[htl.prevbo] ^ bytes1[htl.prevbo]) << 8)
                        | (bytes0[htl.prevbo+1] ^ bytes1[htl.prevbo+1]);
                  xhash = (bytes0[htl.prevbo+2] ^ bytes1[htl.prevbo+2]) >> 4;
        const uint32_t xorslot = atomic_inc(&nslots[0][xorbucketid]);
        if (xorslot >= NSLOTS)
          continue;
        tree xort = tree_create4(bucketid, s0, s1, xhash);
        // __global slot0 *xs = &htl.hta.trees0[1][xorbucketid][xorslot];
         __global slot0 *xs = &tree0_ptr(heap0, 1)[xorbucketid][xorslot];
        xs->attr = xort;
        xs->hash[0].word = pslot0->hash[0].word ^ pslot1->hash[0].word;
        xs->hash[1].word = pslot0->hash[1].word ^ pslot1->hash[1].word;
        xs->hash[2].word = pslot0->hash[2].word ^ pslot1->hash[2].word;
        xs->hash[3].word = pslot0->hash[3].word ^ pslot1->hash[3].word;
        xs->hash[4].word = pslot0->hash[4].word ^ pslot1->hash[4].word;
      }
    }
  }
}
__kernel void digit_3(__global uint32_t *heap0,
                      __global uint32_t *heap1,
                      __global bsizes *nslots) {
  htlayout htl = htlayout_create_2(3);
  collisiondata cd;
  const uint32_t id = get_global_id(0);
  for (uint32_t bucketid=id; bucketid < NBUCKETS; bucketid += get_global_size(0)) {
    collisiondata_clear(&cd); 
//     __global slot0 *buck = htl.hta.trees0[1][bucketid];
    __global slot0 *buck = tree0_ptr(heap0, 1)[bucketid];    
    uint32_t bsize = equi_getnslots(nslots, 2, bucketid);
    for (uint32_t s1 = 0; s1 < bsize; s1++) {
      __global const slot0 *pslot1 = buck + s1;
      if (!collisiondata_addslot(&cd, s1, htlayout_getxhash0(htl.prevbo, pslot1)))  
        continue;
      for (; collisiondata_nextcollision(&cd); ) {
        const uint32_t s0 = collisiondata_slot(&cd);
        __global const slot0 *pslot0 = buck + s0;
        if (htlayout_equal(htl.prevhashunits, pslot0->hash, pslot1->hash))
          continue;
        uint32_t xorbucketid;
        uint32_t xhash;
        __global const uint8_t *bytes0 = pslot0->hash->bytes, *bytes1 = pslot1->hash->bytes;
        xorbucketid = ((((uint32_t)(bytes0[htl.prevbo] ^ bytes1[htl.prevbo]) & 0xf) << 8)
                          | (bytes0[htl.prevbo+1] ^ bytes1[htl.prevbo+1])) << 4
                  | (xhash = bytes0[htl.prevbo+2] ^ bytes1[htl.prevbo+2]) >> 4;
        xhash &= 0xf;
        const uint32_t xorslot = atomic_inc(&nslots[1][xorbucketid]);
        if (xorslot >= NSLOTS)
          continue;
        tree xort = tree_create4(bucketid, s0, s1, xhash);
//         __global slot1 *xs = &htl.hta.trees1[1][xorbucketid][xorslot];
        __global slot1 *xs = &tree1_ptr(heap1, 1)[xorbucketid][xorslot];
        xs->attr = xort;
        xs->hash[0].word = pslot0->hash[1].word ^ pslot1->hash[1].word;
        xs->hash[1].word = pslot0->hash[2].word ^ pslot1->hash[2].word;
        xs->hash[2].word = pslot0->hash[3].word ^ pslot1->hash[3].word;
        xs->hash[3].word = pslot0->hash[4].word ^ pslot1->hash[4].word;
      }
    }
  }
}
__kernel void digit_4(__global uint32_t *heap0,
                      __global uint32_t *heap1,
                      __global bsizes *nslots) {
  htlayout htl = htlayout_create_2(4);
  collisiondata cd;
  const uint32_t id = get_global_id(0);
  for (uint32_t bucketid=id; bucketid < NBUCKETS; bucketid += get_global_size(0)) {
    collisiondata_clear(&cd); 
//     __global slot1 *buck = htl.hta.trees1[1][bucketid];
    __global slot1 *buck = tree1_ptr(heap1, 1)[bucketid];    
    uint32_t bsize = equi_getnslots(nslots, 3, bucketid);
    for (uint32_t s1 = 0; s1 < bsize; s1++) {
      __global const slot1 *pslot1 = buck + s1;
      if (!collisiondata_addslot(&cd, s1, htlayout_getxhash1(htl.prevbo, pslot1)))
        continue;
      for (; collisiondata_nextcollision(&cd); ) {
        const uint32_t s0 = collisiondata_slot(&cd);
        __global const slot1 *pslot0 = buck + s0;
        if (htlayout_equal(htl.prevhashunits, pslot0->hash, pslot1->hash))
          continue;
        uint32_t xorbucketid;
        uint32_t xhash;
        __global const uint8_t *bytes0 = pslot0->hash->bytes, *bytes1 = pslot1->hash->bytes;
        xorbucketid = ((uint32_t)(bytes0[htl.prevbo] ^ bytes1[htl.prevbo]) << 8)
                        | (bytes0[htl.prevbo+1] ^ bytes1[htl.prevbo+1]);
                  xhash = (bytes0[htl.prevbo+2] ^ bytes1[htl.prevbo+2]) >> 4;
        const uint32_t xorslot = atomic_inc(&nslots[0][xorbucketid]);
        if (xorslot >= NSLOTS)
          continue;
        tree xort = tree_create4(bucketid, s0, s1, xhash);
//         __global slot0 *xs = &htl.hta.trees0[2][xorbucketid][xorslot];
        __global slot0 *xs = &tree0_ptr(heap0, 2)[xorbucketid][xorslot];        
        xs->attr = xort;
        xs->hash[0].word = pslot0->hash[0].word ^ pslot1->hash[0].word;
        xs->hash[1].word = pslot0->hash[1].word ^ pslot1->hash[1].word;
        xs->hash[2].word = pslot0->hash[2].word ^ pslot1->hash[2].word;
        xs->hash[3].word = pslot0->hash[3].word ^ pslot1->hash[3].word;
      }
    }
  }
}
__kernel void digit_5(__global uint32_t *heap0,
                      __global uint32_t *heap1,
                      __global bsizes *nslots) {
  htlayout htl = htlayout_create_2(5);
  collisiondata cd;
  const uint32_t id = get_global_id(0);
  for (uint32_t bucketid=id; bucketid < NBUCKETS; bucketid += get_global_size(0)) {
    collisiondata_clear(&cd); 
//     __global slot0 *buck = htl.hta.trees0[2][bucketid];
    __global slot0 *buck = tree0_ptr(heap0, 2)[bucketid];    
    uint32_t bsize = equi_getnslots(nslots, 4, bucketid);
    for (uint32_t s1 = 0; s1 < bsize; s1++) {
      __global const slot0 *pslot1 = buck + s1;
      if (!collisiondata_addslot(&cd, s1, htlayout_getxhash0(htl.prevbo, pslot1)))
        continue;
      for (; collisiondata_nextcollision(&cd); ) {
        const uint32_t s0 = collisiondata_slot(&cd);
        __global const slot0 *pslot0 = buck + s0;
        if (htlayout_equal(htl.prevhashunits, pslot0->hash, pslot1->hash))
          continue;
        uint32_t xorbucketid;
        uint32_t xhash;
        __global const uint8_t *bytes0 = pslot0->hash->bytes, *bytes1 = pslot1->hash->bytes;
        xorbucketid = ((((uint32_t)(bytes0[htl.prevbo] ^ bytes1[htl.prevbo]) & 0xf) << 8)
                          | (bytes0[htl.prevbo+1] ^ bytes1[htl.prevbo+1])) << 4
                  | (xhash = bytes0[htl.prevbo+2] ^ bytes1[htl.prevbo+2]) >> 4;
        xhash &= 0xf;
        const uint32_t xorslot = atomic_inc(&nslots[1][xorbucketid]);
        if (xorslot >= NSLOTS)
          continue;
        tree xort = tree_create4(bucketid, s0, s1, xhash);
//         __global slot1 *xs = &htl.hta.trees1[2][xorbucketid][xorslot];
        __global slot1 *xs = &tree1_ptr(heap1, 2)[xorbucketid][xorslot];        
        xs->attr = xort;
        xs->hash[0].word = pslot0->hash[1].word ^ pslot1->hash[1].word;
        xs->hash[1].word = pslot0->hash[2].word ^ pslot1->hash[2].word;
        xs->hash[2].word = pslot0->hash[3].word ^ pslot1->hash[3].word;
      }
    }
  }
}
__kernel void digit_6(__global uint32_t *heap0,
                      __global uint32_t *heap1,
                      __global bsizes *nslots) {
  htlayout htl = htlayout_create_2(6);
  collisiondata cd;
  const uint32_t id = get_global_id(0);
  for (uint32_t bucketid=id; bucketid < NBUCKETS; bucketid += get_global_size(0)) {
    collisiondata_clear(&cd); 
//     __global slot1 *buck = htl.hta.trees1[2][bucketid];
    __global slot1 *buck = tree1_ptr(heap1, 2)[bucketid];    
    uint32_t bsize = equi_getnslots(nslots, 5, bucketid);
    for (uint32_t s1 = 0; s1 < bsize; s1++) {
      __global const slot1 *pslot1 = buck + s1;
      if (!collisiondata_addslot(&cd, s1, htlayout_getxhash1(htl.prevbo, pslot1)))
        continue;
      for (; collisiondata_nextcollision(&cd); ) {
        const uint32_t s0 = collisiondata_slot(&cd);
        __global const slot1 *pslot0 = buck + s0;
        if (htlayout_equal(htl.prevhashunits, pslot0->hash, pslot1->hash))
          continue;
        uint32_t xorbucketid;
        uint32_t xhash;
        __global const uint8_t *bytes0 = pslot0->hash->bytes, *bytes1 = pslot1->hash->bytes;
        xorbucketid = ((uint32_t)(bytes0[htl.prevbo] ^ bytes1[htl.prevbo]) << 8)
                        | (bytes0[htl.prevbo+1] ^ bytes1[htl.prevbo+1]);
                  xhash = (bytes0[htl.prevbo+2] ^ bytes1[htl.prevbo+2]) >> 4;
        const uint32_t xorslot = atomic_inc(&nslots[0][xorbucketid]);
        if (xorslot >= NSLOTS)
          continue;
        tree xort = tree_create4(bucketid, s0, s1, xhash);
//         __global slot0 *xs = &htl.hta.trees0[3][xorbucketid][xorslot];
        __global slot0 *xs = &tree0_ptr(heap0, 3)[xorbucketid][xorslot];        
        xs->attr = xort;
        xs->hash[0].word = pslot0->hash[1].word ^ pslot1->hash[1].word;
        xs->hash[1].word = pslot0->hash[2].word ^ pslot1->hash[2].word;
      }
    }
  }
}
__kernel void digit_7(__global uint32_t *heap0,
                      __global uint32_t *heap1,
                      __global bsizes *nslots) {
  htlayout htl = htlayout_create_2(7);
  collisiondata cd;
  const uint32_t id = get_global_id(0);
  for (uint32_t bucketid=id; bucketid < NBUCKETS; bucketid += get_global_size(0)) {
    collisiondata_clear(&cd); 
//     __global slot0 *buck = htl.hta.trees0[3][bucketid];
    __global slot0 *buck = tree0_ptr(heap0, 3)[bucketid];    
    uint32_t bsize = equi_getnslots(nslots, 6, bucketid);
    for (uint32_t s1 = 0; s1 < bsize; s1++) {
      __global const slot0 *pslot1 = buck + s1;
      if (!collisiondata_addslot(&cd, s1, htlayout_getxhash0(htl.prevbo, pslot1)))
        continue;
      for (; collisiondata_nextcollision(&cd); ) {
        const uint32_t s0 = collisiondata_slot(&cd);
        __global const slot0 *pslot0 = buck + s0;
        if (htlayout_equal(htl.prevhashunits, pslot0->hash, pslot1->hash))
          continue;
        uint32_t xorbucketid;
        uint32_t xhash;
        __global const uint8_t *bytes0 = pslot0->hash->bytes, *bytes1 = pslot1->hash->bytes;
        xorbucketid = ((((uint32_t)(bytes0[htl.prevbo] ^ bytes1[htl.prevbo]) & 0xf) << 8)
                          | (bytes0[htl.prevbo+1] ^ bytes1[htl.prevbo+1])) << 4
                  | (xhash = bytes0[htl.prevbo+2] ^ bytes1[htl.prevbo+2]) >> 4;
        xhash &= 0xf;
        const uint32_t xorslot = atomic_inc(&nslots[1][xorbucketid]);
        if (xorslot >= NSLOTS)
          continue;
        tree xort = tree_create4(bucketid, s0, s1, xhash);
//         __global slot1 *xs = &htl.hta.trees1[3][xorbucketid][xorslot];
        __global slot1 *xs = &tree1_ptr(heap1, 3)[xorbucketid][xorslot];        
        xs->attr = xort;
        xs->hash[0].word = pslot0->hash[0].word ^ pslot1->hash[0].word;
        xs->hash[1].word = pslot0->hash[1].word ^ pslot1->hash[1].word;
      }
    }
  }
}
__kernel void digit_8(__global uint32_t *heap0,
                      __global uint32_t *heap1,
                      __global bsizes *nslots) {
  htlayout htl = htlayout_create_2(8);
  collisiondata cd;
  const uint32_t id = get_global_id(0);
  for (uint32_t bucketid=id; bucketid < NBUCKETS; bucketid += get_global_size(0)) {
    collisiondata_clear(&cd); 
//     __global slot1 *buck = htl.hta.trees1[3][bucketid];
    __global slot1 *buck = tree1_ptr(heap1, 3)[bucketid];    
    uint32_t bsize = equi_getnslots(nslots, 7, bucketid);
    for (uint32_t s1 = 0; s1 < bsize; s1++) {
      __global const slot1 *pslot1 = buck + s1;          // OPTIMIZE BY UPDATING PREVIOUS
      if (!collisiondata_addslot(&cd, s1, htlayout_getxhash1(htl.prevbo, pslot1)))
        continue;
      for (; collisiondata_nextcollision(&cd); ) {
        const uint32_t s0 = collisiondata_slot(&cd);
        __global const slot1 *pslot0 = buck + s0;
        if (htlayout_equal(htl.prevhashunits, pslot0->hash, pslot1->hash))
          continue;
        uint32_t xorbucketid;
        uint32_t xhash;
        __global const uint8_t *bytes0 = pslot0->hash->bytes, *bytes1 = pslot1->hash->bytes;
        xorbucketid = ((uint32_t)(bytes0[htl.prevbo] ^ bytes1[htl.prevbo]) << 8)
                        | (bytes0[htl.prevbo+1] ^ bytes1[htl.prevbo+1]);
                  xhash = (bytes0[htl.prevbo+2] ^ bytes1[htl.prevbo+2]) >> 4;
        const uint32_t xorslot = atomic_inc(&nslots[0][xorbucketid]);
        if (xorslot >= NSLOTS)
          continue;
        tree xort = tree_create4(bucketid, s0, s1, xhash);
//         __global slot0 *xs = &htl.hta.trees0[4][xorbucketid][xorslot];
        __global slot0 *xs = &tree0_ptr(heap0, 4)[xorbucketid][xorslot];     
        xs->attr = xort;
        xs->hash[0].word = pslot0->hash[1].word ^ pslot1->hash[1].word;
      }
    }
  }
}
#endif //UNROLL

__kernel void digitK(__global uint32_t *heap0,
                     __global uint32_t *heap1,
                     __global bsizes *nslots,
                     __global proof *sols,
                     __global uint32_t *nsols) {
  collisiondata cd;
  htlayout htl = htlayout_create_2(WK);
  const uint32_t id = get_global_id(0);
  for (uint32_t bucketid = id; bucketid < NBUCKETS; bucketid += get_global_size(0)) {
    collisiondata_clear(&cd); 
    __global slot0 *buck = tree0_ptr(heap0, (WK-1)/2)[bucketid];
    uint32_t bsize = equi_getnslots(nslots, WK-1, bucketid);
    for (uint32_t s1 = 0; s1 < bsize; s1++) {
      __global const slot0 *pslot1 = buck + s1;
      if (!collisiondata_addslot(&cd, s1, htlayout_getxhash0(htl.prevbo, pslot1))) // assume WK odd
        continue;
      for (; collisiondata_nextcollision(&cd); ) {
        const uint32_t s0 = collisiondata_slot(&cd);
        __global const slot0 *pslot0 = buck + s0;
        if (htlayout_equal(htl.prevhashunits, pslot0->hash, pslot1->hash)) {
          tree xort = tree_create3(bucketid, s0, s1);
          equi_candidate(heap0, heap1, sols, nsols, xort);
        }
      }
    }
  }
}
