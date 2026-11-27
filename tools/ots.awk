# tools/ots.awk - F16b Winternitz-4 one-time signature over SHA-256.
#
# Pure gawk: no C, no Python, no external crypto process for the OTS math.
# SHA-256 is implemented below and cross-checked against sha256sum by the
# selftest and by tools/ots_gate.sh.
#
# Scheme (one-time signature, w=4):
#   digits  = 64 nibbles of the 32-byte manifest root, high nibble first,
#             followed by a 3-nibble checksum sum(15-digit) over those 64.
#   sk_i    = SHA-256(master || root || LE32(i) || "NaN0S-F16b-OTS-sk-v1")
#   pk_i    = H^15(sk_i)
#   sig_i   = H^digit_i(sk_i)
#   pubkey  = SHA-256(pk_0 || ... || pk_66)          (32 bytes)
#   key id  = first 16 bytes of pubkey
#   anchor  = "OTSA0001" || keyid || pubkey || zeros (512 bytes at 0x1FE00)
#
# Every distinct root gets an independent one-time key derived from the
# offline 32-byte master seed.  The same root rebuilt deterministically gets
# the same key and signature; two different roots never share a chain.
#
# Commands:
#   CMD=selftest
#   CMD=sign    MASTER=hex ROOT=hex   SIGOUT= PUBOUT= KIDOUT= ANCHORHEXOUT=
#   CMD=verify  ROOT=hex SIGFILE= PUB=hex
#   CMD=fingerprint MASTER=hex
#   CMD=digits  ROOT=hex
#
# LC_ALL=C is required for printf "%c" byte output.

BEGIN {
  for (i = 0; i < 256; i++) ord[sprintf("%c", i)] = i
  split("428a2f98 71374491 b5c0fbcf e9b5dba5 3956c25b 59f111f1 923f82a4 ab1c5ed5 " \
        "d807aa98 12835b01 243185be 550c7dc3 72be5d74 80deb1fe 9bdc06a7 c19bf174 " \
        "e49b69c1 efbe4786 0fc19dc6 240ca1cc 2de92c6f 4a7484aa 5cb0a9dc 76f988da " \
        "983e5152 a831c66d b00327c8 bf597fc7 c6e00bf3 d5a79147 06ca6351 14292967 " \
        "27b70a85 2e1b2138 4d2c6dfc 53380d13 650a7354 766a0abb 81c2c92e 92722c85 " \
        "a2bfe8a1 a81a664b c24b8b70 c76c51a3 d192e819 d6990624 f40e3585 106aa070 " \
        "19a4c116 1e376c08 2748774c 34b0bcb5 391c0cb3 4ed8aa4a 5b9cca4f 682e6ff3 " \
        "748f82ee 78a5636f 84c87814 8cc70208 90befffa a4506ceb bef9a3f7 c67178f2", KKW, " ")
  for (i = 1; i <= 64; i++) K[i-1] = strtonum("0x" KKW[i])
  DOMSK = "NaN0S-F16b-OTS-sk-v1"
  DOMSKHEX = asciihex(DOMSK)
  ANCHORMAGIC = "OTSA0001"
  ANCHORMAGICHEX = asciihex(ANCHORMAGIC)

  if (CMD == "selftest") {
    e = sha256_hex("")
    a = sha256_hex(asciihex("abc"))
    if (e != "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855") {
      print "ots selftest: FAIL empty: " e > "/dev/stderr"; exit 1
    }
    if (a != "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad") {
      print "ots selftest: FAIL abc: " a > "/dev/stderr"; exit 1
    }
    # A root that exercises a-f digits: the signer and verifier must use the
    # numeric value, not gawk's "f"+0 == 0 coercion.
    ts_root = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    ts = sha256_hex("00")
    ots_sign("00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff", ts_root)
    if (!ots_verify(ts_root, OTS_SIG, OTS_PUB)) {
      print "ots selftest: FAIL hex-digit round trip" > "/dev/stderr"; exit 1
    }
    print "ots selftest: SHA-256 NIST vectors + hex-digit OTS OK"
    exit 0
  }
  if (CMD == "digits") { print ots_digits(ROOT); exit 0 }
  if (CMD == "hash") { print sha256_hex(HEX); exit 0 }
  if (CMD == "fingerprint") {
    if (length(MASTER) != 64) { print "ots: bad master" > "/dev/stderr"; exit 1 }
    print substr(sha256_hex(asciihex("NaN0S-F16b-master-id-v1") MASTER), 1, 32)
    exit 0
  }
  if (CMD == "sign") {
    if (length(MASTER) != 64) { print "ots sign: master must be 32 bytes" > "/dev/stderr"; exit 1 }
    if (length(ROOT) != 64) { print "ots sign: root must be 32 bytes" > "/dev/stderr"; exit 1 }
    ots_sign(MASTER, ROOT)
    print OTS_SIG > SIGOUT; close(SIGOUT)
    print OTS_PUB > PUBOUT; close(PUBOUT)
    print OTS_KID > KIDOUT; close(KIDOUT)
    print OTS_ANCHORHEX > ANCHORHEXOUT; close(ANCHORHEXOUT)
    printf "ots_sign: keyid %s pub %s sig %d bytes anchor %s\n", \
      OTS_KID, substr(OTS_PUB, 1, 16), length(OTS_SIG)/2, substr(OTS_PUB, 1, 16)
    exit 0
  }
  if (CMD == "verify") {
    s = ""
    if ((getline s < SIGFILE) <= 0) { print "ots verify: cannot read sig" > "/dev/stderr"; exit 1 }
    close(SIGFILE)
    if (length(ROOT) != 64 || length(PUB) != 64) {
      print "ots verify: bad root/pub length" > "/dev/stderr"; exit 1
    }
    if (!ots_verify(ROOT, s, PUB)) { print "ots verify: FAIL" > "/dev/stderr"; exit 1 }
    print "ots verify: OK keyid " substr(PUB, 1, 32)
    exit 0
  }
  print "ots: unknown CMD " CMD > "/dev/stderr"; exit 2
}

# ---------------------------------------------------------------- SHA-256
function add32(a, b) { return (a + b) % 4294967296 }
function ror(x, n) { return or(rshift(x, n), and(lshift(x, 32 - n), 4294967295)) }
function ch(x, y, z) { return xor(and(x, y), and(compl(x), z)) }
function maj(x, y, z) { return xor(xor(and(x, y), and(x, z)), and(y, z)) }
function bsig0(x) { return xor(xor(ror(x, 2), ror(x, 13)), ror(x, 22)) }
function bsig1(x) { return xor(xor(ror(x, 6), ror(x, 11)), ror(x, 25)) }
function ssig0(x) { return xor(xor(ror(x, 7), ror(x, 18)), rshift(x, 3)) }
function ssig1(x) { return xor(xor(ror(x, 17), ror(x, 19)), rshift(x, 10)) }

function asciihex(s,   i, h) {
  h = ""
  for (i = 1; i <= length(s); i++) h = h sprintf("%02x", ord[substr(s, i, 1)])
  return h
}

function sha256_hex(h,   n, i, b) {
  n = length(h) / 2
  for (i = 0; i < n; i++) b[i] = strtonum("0x" substr(h, 2*i+1, 2))
  return sha256_b(b, n)
}

function sha256_b(b, n,   m, i, total, bits, hi, lo, off, w, a, bb, c, d, e, f, g, hh, t1, t2, H0,H1,H2,H3,H4,H5,H6,H7) {
  for (i = 0; i < n; i++) m[i] = b[i]
  total = n
  m[total++] = 0x80
  while (total % 64 != 56) m[total++] = 0
  bits = n * 8
  hi = int(bits / 4294967296)
  lo = bits % 4294967296
  m[total++] = int(hi / 16777216) % 256
  m[total++] = int(hi / 65536) % 256
  m[total++] = int(hi / 256) % 256
  m[total++] = hi % 256
  m[total++] = int(lo / 16777216) % 256
  m[total++] = int(lo / 65536) % 256
  m[total++] = int(lo / 256) % 256
  m[total++] = lo % 256

  H0 = strtonum("0x6a09e667"); H1 = strtonum("0xbb67ae85")
  H2 = strtonum("0x3c6ef372"); H3 = strtonum("0xa54ff53a")
  H4 = strtonum("0x510e527f"); H5 = strtonum("0x9b05688c")
  H6 = strtonum("0x1f83d9ab"); H7 = strtonum("0x5be0cd19")

  for (off = 0; off < total; off += 64) {
    for (i = 0; i < 16; i++)
      w[i] = m[off+4*i]*16777216 + m[off+4*i+1]*65536 + m[off+4*i+2]*256 + m[off+4*i+3]
    for (i = 16; i < 64; i++)
      w[i] = add32(add32(ssig1(w[i-2]), w[i-7]), add32(ssig0(w[i-15]), w[i-16]))
    a = H0; bb = H1; c = H2; d = H3; e = H4; f = H5; g = H6; hh = H7
    for (i = 0; i < 64; i++) {
      t1 = add32(add32(add32(hh, bsig1(e)), ch(e, f, g)), add32(K[i], w[i]))
      t2 = add32(bsig0(a), maj(a, bb, c))
      hh = g; g = f; f = e; e = add32(d, t1)
      d = c; c = bb; bb = a; a = add32(t1, t2)
    }
    H0 = add32(H0, a); H1 = add32(H1, bb); H2 = add32(H2, c); H3 = add32(H3, d)
    H4 = add32(H4, e); H5 = add32(H5, f); H6 = add32(H6, g); H7 = add32(H7, hh)
  }
  return sprintf("%08x%08x%08x%08x%08x%08x%08x%08x", H0, H1, H2, H3, H4, H5, H6, H7)
}

# ------------------------------------------------------- Winternitz-4 OTS
function le32hex(i) {
  return sprintf("%02x%02x%02x%02x", i % 256, int(i/256) % 256, int(i/65536) % 256, int(i/16777216) % 256)
}

function hexval(c) { return index("0123456789abcdef", tolower(c)) - 1 }

function ots_digits(roothex,   i, b, hi, lo, s, d) {
  if (length(roothex) != 64) return ""
  d = ""; s = 0
  for (i = 1; i <= 32; i++) {
    b = strtonum("0x" substr(roothex, 2*i-1, 2))
    hi = int(b / 16); lo = b % 16
    d = d sprintf("%x%x", hi, lo)
    s += (15 - hi) + (15 - lo)
  }
  d = d sprintf("%x%x%x", int(s/256) % 16, int(s/16) % 16, s % 16)
  return d
}

function ots_sign(master, root,   d, i, j, v, dg, pk, sig, cat, pub, kid) {
  d = ots_digits(root)
  if (length(d) != 67) { print "ots sign: bad digits" > "/dev/stderr"; exit 1 }
  for (i = 0; i < 67; i++) {
    v = sha256_hex(master root le32hex(i) DOMSKHEX)
    sig[i] = v
    dg = hexval(substr(d, i+1, 1))
    for (j = 1; j <= 15; j++) {
      v = sha256_hex(v)
      if (j == dg) sig[i] = v
    }
    pk[i] = v
  }
  cat = ""; for (i = 0; i < 67; i++) cat = cat pk[i]
  pub = sha256_hex(cat)
  cat = ""; for (i = 0; i < 67; i++) cat = cat sig[i]
  OTS_SIG = cat
  OTS_PUB = pub
  OTS_KID = substr(pub, 1, 32)
  OTS_ANCHORHEX = ANCHORMAGICHEX OTS_KID pub zeroshex(512 - 8 - 16 - 32)
}

function ots_verify(roothex, sighex, pubhex,   d, i, j, v, need, cat) {
  d = ots_digits(roothex)
  if (length(d) != 67 || length(sighex) != 67*64) return 0
  cat = ""
  for (i = 0; i < 67; i++) {
    v = substr(sighex, i*64 + 1, 64)
    need = 15 - hexval(substr(d, i+1, 1))
    for (j = 0; j < need; j++) v = sha256_hex(v)
    cat = cat v
  }
  return sha256_hex(cat) == pubhex
}

function zeroshex(n,   i, h) {
  h = ""
  for (i = 0; i < n; i++) h = h "00"
  return h
}
