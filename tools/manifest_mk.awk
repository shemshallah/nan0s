# tools/manifest_mk.awk - emit the 4096-byte F16b product manifest.
#
# Layout (little-endian, manifest region at image LBA 120..127,
# physical 0x1EE00..0x1FE00).  The last 512 bytes of the 128-sector kernel
# window (0x1FE00) are a separate 512-byte OTS anchor block, not this file.
#
#   0x000 u32 magic "NMAN"
#   0x004 u32 version 2
#   0x008 u32 build id (first 8 hex of SHA-256(boot||kernel||guest digests))
#   0x00C u32 flags 3 = SHA-256 + HMAC-SHA-256 + Winternitz-4 OTS
#   0x010 u32 region count 3
#   0x014 u32 header length 0x40
#   0x018 u32 root offset 0x128
#   0x01C u32 tag offset 0x148
#   0x020 u32 OTS algorithm 1 (Winternitz-4 over SHA-256)
#   0x024 u32 OTS w 4
#   0x028 u32 OTS units 67 (64 message nibbles + 3 checksum nibbles)
#   0x02C u32 OTS signature offset 0x200
#   0x030 u32 OTS signature bytes 0x860 (2144)
#   0x034..0x03F zero
#   0x040 boot   region: id 1, algo 1, offset 0,     size 512,    SHA-256
#   0x078 kernel region: id 2, algo 1, offset 512,   size 60928,  SHA-256
#   0x0B0 guest  region: id 3, algo 1, offset 66048, size 8*LMAX, SHA-256
#   0x0E8 key id 16 bytes (first 16 bytes of pubkey)
#   0x0F8 OTS public key 32 bytes
#   0x118..0x127 zero
#   0x128 root = SHA-256(manifest[0..0xE7])
#   0x148 tag  = HMAC-SHA-256(build key, root)
#   0x168..0x1FF zero
#   0x200 signature = 67 * 32 bytes
#   0xA60..0xFFF zero
#
# The root deliberately covers only the header and region table.  The OTS
# key id/public key are anchored separately in the 512-byte block at 0x1FE00
# (patched by manifest_build.sh from the offline signer), so a key or key-id
# mutation fails the OTS path rather than the root path.
BEGIN {
  M = 4294967296
  puthex32("4E414D4E")            # "NMAN"
  put32(2)                        # version
  puthex32(BID)
  put32(3)                        # flags
  put32(3)                        # region count
  put32(0x40)                     # header length
  put32(0x128)                    # root offset
  put32(0x148)                    # tag offset
  put32(1)                        # OTS algo: Winternitz-4/SHA-256
  put32(4)                        # OTS w
  put32(67)                       # OTS units
  put32(0x200)                    # OTS signature offset
  put32(0x860)                    # OTS signature bytes
  for (i = 0; i < 3; i++) put32(0)
  entry(1, 0, 512, HB)
  entry(2, 512, 60928, HK)
  entry(3, 66048, GSZ, HG)
  puthex(KID, 16)
  puthex(PK, 32)
  for (i = 0; i < 4; i++) put32(0)
  puthex(ROOT, 32)
  puthex(TAG, 32)
  for (i = 0; i < 38; i++) put32(0)
  puthex(SIG, 2144)
  for (i = 0; i < 0x1000 - 0xA60; i++) printf "%c", 0
  exit 0
}
function entry(id, off, size, dig) {
  put32(id); put32(1); put64(off); put64(size); puthex(dig, 32)
}
function put32(v,   x) {
  x = v % M
  if (x < 0) x += M
  printf "%c%c%c%c", x % 256, int(x / 256) % 256, int(x / 65536) % 256, int(x / 16777216) % 256
}
function put64(v) {
  put32(v % M)
  put32(int(v / M))
}
function puthex32(h) {
  put32(strtonum("0x" h))
}
function puthex(h, n,   i) {
  for (i = 1; i <= n; i++)
    printf "%c", strtonum("0x" substr(h, 2 * i - 1, 2))
}
