/* nan16-abi.h - NaN16 C ABI contract shared by tcc0 and ncc.
 *
 * The product ABI is the one ncc emits and the NaN16 loader executes.
 * Registers:
 *   r0  = constant 0
 *   r13 = constant 1
 *   r14 = C stack pointer (grows up in guest word memory)
 *   r15 = hardware link register for NaN CALL/RET
 *   r1  = first scalar result (64-bit values use a (lo,hi) pair)
 *
 * ncc's C frames are software frames reached through the ncc runtime.  The
 * frame pointer is a BYTE address; word offsets are fp/4:
 *   fp[0] = caller fp
 *   fp[1] = return IP
 *   fp[2] = caller SP to restore
 *   fp[3] = frame size in words (used to derive the next frame)
 * Arguments are copied by the callee from the caller's eval stack into the
 * frame at the declared parameter offsets.  TCC's backend must match this
 * layout, including 64-bit argument pairs, struct copies and varargs.
 *
 * The current ncc ABI is still 32-bit for pointers, size_t and double.  The
 * 64-bit ABI work (P0.2) changes NAN16_SIZEOF_PTR to 8; the frame layout and
 * register roles stay the same.
 */
#ifndef NAN16_ABI_H
#define NAN16_ABI_H

#include <stdint.h>

#define NAN16_ABI_VERSION 1

#define NAN16_REG_ZERO 0
#define NAN16_REG_ONE  13
#define NAN16_REG_SP   14
#define NAN16_REG_LINK 15
#define NAN16_REG_COUNT 16

#define NAN16_FRAME_OLD_FP 0
#define NAN16_FRAME_RET    1
#define NAN16_FRAME_SP     2
#define NAN16_FRAME_SIZE   3
#define NAN16_FRAME_WORDS  4
#define NAN16_FRAME_BYTES  (NAN16_FRAME_WORDS * 4)

/* Current baseline; the 64-bit ABI flips PTR/SIZE_T to 8. */
#define NAN16_SIZEOF_CHAR   1
#define NAN16_SIZEOF_SHORT  2
#define NAN16_SIZEOF_INT    4
#define NAN16_SIZEOF_LONG   4
#define NAN16_SIZEOF_LLONG  8
#define NAN16_SIZEOF_FLOAT  4
#define NAN16_SIZEOF_DOUBLE 4
#define NAN16_SIZEOF_PTR    4
#define NAN16_SIZEOF_SIZE_T 4

#define NAN16_ALIGN_LLONG   8
#define NAN16_ALIGN_PTR     4
#define NAN16_ALIGN_DOUBLE  4

#define NAN16_VARARGS_OFFSET 16  /* fp+16: 64-byte varargs area */
#define NAN16_VARARGS_BYTES  64

/* NaN word transport, identical to the VM's nan_mkword. */
static const uint16_t nan16_heads[4] = {0x7FF1, 0xFFF1, 0x7FF8, 0xFFF8};

static inline uint64_t nan16_mkword(uint32_t payload, int n)
{
    uint32_t far = nan16_heads[n & 3];
    uint16_t near = nan16_heads[(n >> 2) & 3];
    return (uint64_t)((far >> 8) | ((far & 0xFF) << 8))
         | ((uint64_t)payload << 16)
         | ((uint64_t)near << 48);
}

static inline uint32_t nan16_payload(uint64_t w) { return (uint32_t)(w >> 16); }
static inline uint16_t nan16_near(uint64_t w) { return (uint16_t)(w >> 48); }
static inline uint16_t nan16_far(uint64_t w)
{
    return (uint16_t)(((w & 0xFF) << 8) | ((w >> 8) & 0xFF));
}

#endif
