# tools/manifest_mk.awk - emit the 512-byte F16 product manifest.
#
# Layout (little-endian, all offsets in the manifest region at image LBA 128):
#   0x000 u32 magic "NMAN"
#   0x004 u32 version 1
#   0x008 u32 build id
#   0x00C u32 flags (1 = SHA-256 region digests + HMAC-SHA-256 auth tag)
#   0x010 u32 region count 3
#   0x014 u32 header length 0x40
#   0x018 u32 root offset 0xE8
#   0x01C u32 tag offset 0x108
#   0x020 32 bytes reserved (zero)
#   0x040 region 0: id 1 (boot),   algo 1, off 0,     size 512,   digest
#   0x078 region 1: id 2 (kernel), algo 1, off 512,   size 65024, digest
#   0x0B0 region 2: id 3 (guest),  algo 1, off 66048, size GSZ,   digest
#   0x0E8 root = SHA-256(manifest[0..0xE7])
#   0x108 tag  = HMAC-SHA-256(build key, root)
#   0x128..0x1FF zero
#
# Inputs are hex strings so values above 2^31 are unambiguous under gawk.
BEGIN {
  M = 4294967296
  # magic bytes "NMAN"
  puthex32("4E414D4E")
  put32(1)
  puthex32(BID)
  put32(1)
  put32(3)
  put32(0x40)
  put32(0xE8)
  put32(0x108)
  for (i = 0; i < 8; i++) put32(0)
  entry(1, 0, 512, HB)
  entry(2, 512, 65024, HK)
  entry(3, 66048, GSZ, HG)
  puthex(ROOT, 32)
  puthex(TAG, 32)
  for (i = 0; i < 512 - 0x128; i++) printf "%c", 0
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
