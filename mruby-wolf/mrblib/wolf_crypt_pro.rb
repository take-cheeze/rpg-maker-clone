# The "Pro-protected" (byte 1 == 0x50) decryption schemes `Wolf::Crypt`
# (wolf.rb) only detected and refused before this file existed. Split out of
# wolf.rb because it is sizeable on its own (a from-scratch SHA-512 and
# AES-128 needed only here) and because keeping the "detect" half (wolf.rb)
# and the "actually decrypt" half (here) in separate files makes it obvious
# at a glance which of the three protection sub-schemes this reader commits
# to (see below) without wading through the byte-level primitives first.
#
# ## What "Pro-protected" actually is
#
# Every protected file's byte 1 is 0x50 (`Wolf::Crypt.protected?`); byte 5
# is a `cryptVersion` that selects one of three unrelated schemes
# (`WolfRPG/FileCoder.hpp`'s `load()`, the real dispatch -- not
# `WolfCryptUtils.hpp`'s `isV35`, a same-named but *different* version gate
# used only inside the "v3.3" scheme's own key derivation):
#
#   * `cryptVersion < 0x55`: "v3.1" -- `WolfDataDecrypt.hpp`'s own
#     `namespace v3_1 { }` is *empty*: WolfTL itself never implemented a
#     decrypt function for this sub-scheme, only the header-skipping logic
#     needed to get past it in `FileCoder::decryptV3_1`. There is no
#     reference to port. Refused by name.
#   * `cryptVersion < 0x57`: "v3.3" -- self-contained (no external secret;
#     `WolfProtKey.hpp`'s `calcProtKey` even recovers the human-chosen
#     protection password *from* an encrypted block `Game.dat` carries), but
#     its key derivation is a ~250-line custom PRNG state machine
#     (`WolfRng.hpp`'s `customRng1`/`customRng2`/`customRng3`, `rngChain`,
#     `aLotOfRngStuff`, each with a dozen modulus-keyed branches) built to
#     key an AES stream for exactly one file (`Game.dat`) via `initCrypt`'s
#     header-byte-derived seeds. Porting and cross-validating ~250 lines of
#     tightly branch-dependent PRNG state by hand, where a single off-by-one
#     produces a *plausible-looking but wrong* key rather than a crash, is
#     exactly the "silently wrong is worse than refusing" case this
#     project's own discipline (see `docs/TODO.md`'s `BanInput`(126) entry)
#     says not to ship without much stronger validation than the time
#     available this session afforded. Refused by name.
#   * `cryptVersion >= 0x57`: "v3.5" -- the actual "Pro" AES-128-CTR scheme,
#     and what a modern editor release (this repo's own bundled sample game
#     is 3.724) would use. **Implemented below**, cross-validated against a
#     real compiled reference binary (see "Cross-validation").
#
# v3.5's key derivation is genuinely simple by comparison: AES-128 key/IV are
# `SHA-512(saltPassword("", dynamicSaltFromTheFile'sOwnBytes,
# hardcodedPerFileTypeStaticSalt))`, i.e. an *empty* human password, salted
# only with bytes the protected file itself already carries plus a small
# hardcoded string that differs per file type (`PRO_MAGIC` below) -- nothing
# external to the file is ever needed, for any of the three sub-schemes
# (`docs/adr/0095-wolf-rpg-editor-pro-protected.md` corrects `docs/TODO.md`'s
# former claim otherwise; see that ADR for the full argument).
#
# ## Cross-validation
#
# Every primitive here (SHA-512, AES-128 key expansion + CTR, the xorshift32
# step, the MSVC-`rand()`-compatible LCG, the ProV3P1 keystream, and the full
# `decrypt_v35` pipeline for all four known file types plus a large buffer
# that exercises the `aesSize` cap branch) was checked byte-for-byte against
# a small standalone C++ harness compiling WolfTL's *actual* vendored headers
# (`/home/user/3rdref/WolfTL/WolfTL/WolfCrypt/*.hpp`) unmodified -- not
# hand-traced from reading them. `mruby-wolf/test/wolf_test.rb`'s
# "Pro-protected v3.5" section asserts this port reproduces that harness's
# recorded output exactly; see `docs/adr/0095-wolf-rpg-editor-pro-protected.md`
# for the harness source and how to reproduce it.
#
# ## Portability
#
# Byte-wise arithmetic only, the same discipline `rgssad.rb` and
# `data_wolf.rb` already follow: SHA-512's 64-bit words are 8-element Arrays
# of 0..255 bytes (never a native/bignum 64-bit integer) with add/xor/shift/
# rotate implemented over those bytes, so nothing here depends on `mrb_int`
# being wider than 32 bits or on `mruby-bigint` supporting 64-bit-wide
# bitwise ops. The handful of 32-bit-scale values (the xorshift32 step, the
# MSVC LCG, the ProV3P1 keystream) follow `Wolf::Crypt.v2`'s own already-
# shipped idiom instead: ordinary `<<`/`^`/`&` immediately re-masked with
# `& 0xFFFF_FFFF`, which `mruby-bigint` already handles (that gem exists
# specifically because mruby 4's compiler pools such literals as bignums;
# see `build_config.rb`'s own comment beside it) and which `Crypt.v2`'s own
# passing unit test already proves works end to end under the trimmed
# mruby build, not just CRuby.
#
# Two further, harder-won portability rules, both found by running the real
# ctest suite rather than only the CRuby prototype (a CRuby-only check would
# have missed both -- see docs/adr/0095-wolf-rpg-editor-pro-protected.md's
# "Cross-validation" section for how each was actually caught):
#
#   * **No `Numeric#zero?`/`#negative?`/`#positive?`.** These come from
#     mruby-numeric-ext's `mrblib`, but this build's `mrbtest` binary does
#     not resolve them for `Integer` (`Numeric.instance_methods(false)`
#     does not list them there, despite the gem compiling in and `Integer`'s
#     own `.ancestors` naming `Numeric`) -- a real, if not fully diagnosed,
#     quirk of this exact mruby configuration, not a mistake in the call
#     sites. `== 0`/`< 0`/`> 0` are used everywhere instead.
#   * **The whole protected file is a byte String, never one big `Array`.**
#     A real CommonEvent.dat routinely exceeds mruby's `MRB_ARY_LENGTH_MAX`
#     (131072, `build/mruby`'s default) -- turning one into a single Array
#     of per-byte integers (as an earlier version of this file did) raises
#     `ArgumentError: array size too big` the moment a real, several-
#     hundred-KB file reaches it, exactly the way `rgssad.rb`'s own
#     `DECRYPT_CHUNK` and `data_wolf.rb`'s own `CHUNK` already exist to
#     avoid for the same reason. `decrypt_pro_v3_p1!` and `region_xcrypt`
#     walk/splice a String via `getbyte`/`setbyte`/`byteslice` instead;
#     `Array`s only ever hold small, bounded things here (round-key
#     schedules, SHA-512 words, and the AES-CTR region -- provably always
#     <= 325 bytes regardless of file size, see `aes_size_for`'s comment).
module Wolf
  module Crypt
    # ---------------------------------------------------------------------
    # SHA-512, with the two custom constant tables WOLF's own copy replaces
    # the standard ones with (`hPrime`, and a final `h[i] += s[i] ^
    # 0x123456789ABCDEF0` in place of the textbook `h[i] += s[i]`) --
    # WolfSha512.hpp's own comments call both out as "custom Wolf specific"
    # changes. The round constants (`K`) and round function shape are
    # otherwise textbook SHA-512.
    #
    # A 64-bit word is represented as an 8-element Array of bytes (0..255),
    # most-significant byte first -- never a native 64-bit integer -- per
    # this file's header "Portability" note. `rotr`/`shr` go through a
    # 64-element bit array (bit 0 = least significant) rather than a clever
    # byte/bit-shift decomposition: it is the version of this that is
    # obviously correct on inspection, and nothing here is hot enough
    # (a handful of 1024-bit message blocks per protected file) to need the
    # faster version.
    module Sha512
      K_HEX = %w[
        428a2f98d728ae22 7137449123ef65cd b5c0fbcfec4d3b2f e9b5dba58189dbbc 3956c25bf348b538
        59f111f1b605d019 923f82a4af194f9b ab1c5ed5da6d8118 d807aa98a3030242 12835b0145706fbe
        243185be4ee4b28c 550c7dc3d5ffb4e2 72be5d74f27b896f 80deb1fe3b1696b1 9bdc06a725c71235
        c19bf174cf692694 e49b69c19ef14ad2 efbe4786384f25e3 0fc19dc68b8cd5b5 240ca1cc77ac9c65
        2de92c6f592b0275 4a7484aa6ea6e483 5cb0a9dcbd41fbd4 76f988da831153b5 983e5152ee66dfab
        a831c66d2db43210 b00327c898fb213f bf597fc7beef0ee4 c6e00bf33da88fc2 d5a79147930aa725
        06ca6351e003826f 142929670a0e6e70 27b70a8546d22ffc 2e1b21385c26c926 4d2c6dfc5ac42aed
        53380d139d95b3df 650a73548baf63de 766a0abb3c77b2a8 81c2c92e47edaee6 92722c851482353b
        a2bfe8a14cf10364 a81a664bbc423001 c24b8b70d0f89791 c76c51a30654be30 d192e819d6ef5218
        d69906245565a910 f40e35855771202a 106aa07032bbd1b8 19a4c116b8d2d0c8 1e376c085141ab53
        2748774cdf8eeb99 34b0bcb5e19b48a8 391c0cb3c5c95a63 4ed8aa4ae3418acb 5b9cca4f7763e373
        682e6ff3d6b2b8a3 748f82ee5defb2fc 78a5636f43172f60 84c87814a1f0ab72 8cc702081a6439ec
        90befffa23631e28 a4506cebde82bde9 bef9a3f7b2c67915 c67178f2e372532b ca273eceea26619c
        d186b8c721c0c207 eada7dd6cde0eb1e f57d4f7fee6ed178 06f067aa72176fba 0a637dc5a2c898a6
        113f9804bef90dae 1b710b35131c471b 28db77f523047d84 32caab7b40c72493 3c9ebe0a15c9bebc
        431d67c49c100d4c 4cc5d4becb3e42b6 597f299cfc657e2a 5fcb6fab3ad6faec 6c44198c4a475817
      ].freeze

      HPRIME_HEX = %w[
        123456789ABCDEF0 FEDCBA9876543210 0F1E2D3C4B5A6978 89ABCDEF01234567
        13579BDF02468ACE F0E1D2C3B4A59687 5A6B7C8D9E0F1A2B 1A2B3C4D5E6F7890
      ].freeze

      # 2 hex chars -> 1 byte, 16 hex chars -> one 8-byte big-endian word.
      def self.word64(hex16)
        Array.new(8) { |i| hex16[i * 2, 2].to_i(16) }
      end

      K = K_HEX.map { |h| word64(h) }.freeze
      HPRIME = HPRIME_HEX.map { |h| word64(h) }.freeze
      XOR_CONST = word64("123456789ABCDEF0").freeze

      # Sum of N 64-bit words mod 2**64, byte by byte from the least
      # significant end with carry propagate -- never a value wider than
      # "byte + a handful of carries" at any point.
      def self.add64(*words)
        result = Array.new(8, 0)
        carry = 0
        7.downto(0) do |i|
          s = carry
          words.each { |w| s += w[i] }
          result[i] = s & 0xFF
          carry = s >> 8
        end
        result
      end

      def self.xor64(a, b); Array.new(8) { |i| a[i] ^ b[i] }; end
      def self.and64(a, b); Array.new(8) { |i| a[i] & b[i] }; end

      # w (8 bytes, MSB first) -> 64-element bit array, bits[0] = LSB.
      def self.to_bits(w)
        bits = Array.new(64)
        w.each_with_index do |byte, bi|
          8.times do |k|
            bit_val = (byte >> (7 - k)) & 1
            from_msb = bi * 8 + k
            bits[63 - from_msb] = bit_val
          end
        end
        bits
      end

      def self.from_bits(bits)
        w = Array.new(8, 0)
        64.times do |bit_from_lsb|
          from_msb = 63 - bit_from_lsb
          bi = from_msb / 8
          k = from_msb % 8
          w[bi] |= (bits[bit_from_lsb] << (7 - k))
        end
        w
      end

      # Logical right shift (zero-filled), 0 <= n < 64.
      def self.shr64(w, n)
        bits = to_bits(w)
        from_bits(Array.new(64) { |i| (i + n < 64) ? bits[i + n] : 0 })
      end

      def self.rotr64(w, n)
        n %= 64
        bits = to_bits(w)
        from_bits(Array.new(64) { |i| bits[(i + n) % 64] })
      end

      def self.ch(x, y, z)
        xor64(and64(x, y), and64(Array.new(8) { |i| 255 - x[i] }, z))
      end

      def self.maj(x, y, z)
        xor64(xor64(and64(x, y), and64(x, z)), and64(y, z))
      end

      def self.big_sig0(x); xor64(xor64(rotr64(x, 28), rotr64(x, 34)), rotr64(x, 39)); end
      def self.big_sig1(x); xor64(xor64(rotr64(x, 14), rotr64(x, 18)), rotr64(x, 41)); end
      def self.sig0(x); xor64(xor64(rotr64(x, 1), rotr64(x, 8)), shr64(x, 7)); end
      def self.sig1(x); xor64(xor64(rotr64(x, 19), rotr64(x, 61)), shr64(x, 6)); end

      # n as an 8-byte big-endian word. Only ever called with a small bit
      # count (this module's own inputs are a few bytes of salted password),
      # so plain division-by-256 stays well inside a 32-bit-safe range --
      # never the general SHA-512 case of a multi-gigabyte message.
      def self.int_to_word64(n)
        w = Array.new(8, 0)
        7.downto(0) do |i|
          w[i] = n % 256
          n /= 256
        end
        w
      end

      # Pads `bytes` (an Array of 0..255) the way WolfSha512.hpp's own
      # `preprocess` does: a single 0x80 marker byte, zero fill, then the
      # bit length in the final 8-byte word (the one before it stays zero --
      # this custom variant never splits the length across two words the
      # way textbook SHA-512's 128-bit length field would for a message
      # anywhere near 2**61 bytes long, which nothing here ever produces).
      # Returns [words, n_buffer] (n_buffer * 16 64-bit words per buffer).
      def self.preprocess(bytes)
        len = bytes.size
        l = len * 8
        n_buffer = ((895 - l) % 1024 + l + 129) / 1024
        total_words = n_buffer * 16
        buffer = Array.new(total_words)
        index = 0
        total_words.times do |i|
          chunk = Array.new(8, 0)
          8.times do |j|
            if index < len
              chunk[j] = bytes[index] & 0xFF
            elsif index == len
              chunk[j] = 0x80
            end
            index += 1
          end
          buffer[i] = chunk
        end
        buffer[total_words - 2] = Array.new(8, 0)
        buffer[total_words - 1] = int_to_word64(l)
        [buffer, n_buffer]
      end

      def self.process(buffer_words, n_buffer)
        h = HPRIME.map(&:dup)
        n_buffer.times do |blk|
          w = Array.new(80)
          16.times { |i| w[i] = buffer_words[(blk * 16) + i] }
          (16...80).each do |j|
            w[j] = add64(w[j - 16], sig0(w[j - 15]), w[j - 7], sig1(w[j - 2]))
          end
          s = h.map(&:dup)
          80.times do |j|
            # The two NOTEs in WolfSha512.hpp: `(s[4] >> 3) ^ Ch(...)` in
            # place of plain `Ch(...)`, and the final `h[i] += s[i] ^
            # 0x123456789ABCDEF0` below, in place of `h[i] += s[i]`.
            temp1 = add64(s[7], big_sig1(s[4]), xor64(shr64(s[4], 3), ch(s[4], s[5], s[6])), K[j], w[j])
            temp2 = add64(big_sig0(s[0]), maj(s[0], s[1], s[2]))
            s[7] = s[6]
            s[6] = s[5]
            s[5] = s[4]
            s[4] = add64(s[3], temp1)
            s[3] = s[2]
            s[2] = s[1]
            s[1] = s[0]
            s[0] = add64(temp1, temp2)
          end
          8.times { |i| h[i] = add64(h[i], xor64(s[i], XOR_CONST)) }
        end
        h
      end

      # 8 words -> a 128-character lowercase hex string, exactly
      # `wolf::sha512::digest`'s own `std::hex << std::setw(16)` formatting.
      def self.digest(h)
        h.map { |w| w.map { |b| sprintf("%02x", b) }.join }.join
      end

      def self.hexdigest(bytes)
        buffer, n_buffer = preprocess(bytes)
        digest(process(buffer, n_buffer))
      end

      # The 4-byte "dynamic salt" `WolfSha512.hpp`'s `calcDynSalt` derives
      # from four of the protected file's own header bytes (7, 11, 12, 13,
      # 14) -- part of why no external key is needed (see this file's
      # header). `data` is a byte String (the whole protected file, which
      # can be several hundred KB -- read via `getbyte` rather than turned
      # into one big `Array`, see this gem's own portability note above on
      # mruby's `MRB_ARY_LENGTH_MAX`).
      def self.calc_dyn_salt(data)
        raise Wolf::Error, "Sha512.calc_dyn_salt: data too small" if data.bytesize <= 0x10
        d0 = data.getbyte(7)
        d1 = data.getbyte(11)
        d2 = data.getbyte(13)
        r0 = (d0 + (2 * d1)) % 0xF6
        r1 = d2 ^ data.getbyte(14)
        r2 = d0 ^ data.getbyte(12)
        # uint8_t wraparound: matches C++'s narrowing-conversion-to-unsigned
        # semantics for a negative intermediate exactly (Ruby's `%` with a
        # positive divisor is already non-negative either way).
        r3 = (d0 + d2 - d1) % 256
        # `.zero?` avoided here (and everywhere else in this file) -- not
        # every mruby build this needs to run under reliably resolves
        # mruby-numeric-ext's `Numeric#zero?`/`#negative?`, so this sticks
        # to the core `==`/`<` comparisons the rest of the codebase already
        # depends on.
        [r0, r1, r2, r3].map { |c| c == 0 ? 1 : c }
      end

      # pwd ++ dynSalt ++ staticSalt, all as Arrays of bytes -- WolfSha512.hpp's
      # own `saltPassword` (v3.5 always calls this with an *empty* pwd).
      def self.salt_password(pwd_bytes, dyn_salt, static_salt_bytes)
        pwd_bytes + dyn_salt + static_salt_bytes
      end
    end

    # ---------------------------------------------------------------------
    # AES-128, key-scheduled the way `WolfAes.hpp` does it -- *not* stock
    # AES: `keyExpansion`'s `i % Nk == 0` branch replaces the textbook
    # `RotWord; SubWord; ^= Rcon` step with WOLF-specific byte mangling
    # (`WolfAes.hpp`'s own comment: "This differs between the original and
    # the WolfRPG version"). Everything else (S-box, ShiftRows, MixColumns,
    # CTR-mode keystream generation and IV increment) is textbook AES-128.
    module Aes
      SBOX = [
        0x63, 0x7C, 0x77, 0x7B, 0xF2, 0x6B, 0x6F, 0xC5, 0x30, 0x01, 0x67, 0x2B, 0xFE, 0xD7, 0xAB, 0x76,
        0xCA, 0x82, 0xC9, 0x7D, 0xFA, 0x59, 0x47, 0xF0, 0xAD, 0xD4, 0xA2, 0xAF, 0x9C, 0xA4, 0x72, 0xC0,
        0xB7, 0xFD, 0x93, 0x26, 0x36, 0x3F, 0xF7, 0xCC, 0x34, 0xA5, 0xE5, 0xF1, 0x71, 0xD8, 0x31, 0x15,
        0x04, 0xC7, 0x23, 0xC3, 0x18, 0x96, 0x05, 0x9A, 0x07, 0x12, 0x80, 0xE2, 0xEB, 0x27, 0xB2, 0x75,
        0x09, 0x83, 0x2C, 0x1A, 0x1B, 0x6E, 0x5A, 0xA0, 0x52, 0x3B, 0xD6, 0xB3, 0x29, 0xE3, 0x2F, 0x84,
        0x53, 0xD1, 0x00, 0xED, 0x20, 0xFC, 0xB1, 0x5B, 0x6A, 0xCB, 0xBE, 0x39, 0x4A, 0x4C, 0x58, 0xCF,
        0xD0, 0xEF, 0xAA, 0xFB, 0x43, 0x4D, 0x33, 0x85, 0x45, 0xF9, 0x02, 0x7F, 0x50, 0x3C, 0x9F, 0xA8,
        0x51, 0xA3, 0x40, 0x8F, 0x92, 0x9D, 0x38, 0xF5, 0xBC, 0xB6, 0xDA, 0x21, 0x10, 0xFF, 0xF3, 0xD2,
        0xCD, 0x0C, 0x13, 0xEC, 0x5F, 0x97, 0x44, 0x17, 0xC4, 0xA7, 0x7E, 0x3D, 0x64, 0x5D, 0x19, 0x73,
        0x60, 0x81, 0x4F, 0xDC, 0x22, 0x2A, 0x90, 0x88, 0x46, 0xEE, 0xB8, 0x14, 0xDE, 0x5E, 0x0B, 0xDB,
        0xE0, 0x32, 0x3A, 0x0A, 0x49, 0x06, 0x24, 0x5C, 0xC2, 0xD3, 0xAC, 0x62, 0x91, 0x95, 0xE4, 0x79,
        0xE7, 0xC8, 0x37, 0x6D, 0x8D, 0xD5, 0x4E, 0xA9, 0x6C, 0x56, 0xF4, 0xEA, 0x65, 0x7A, 0xAE, 0x08,
        0xBA, 0x78, 0x25, 0x2E, 0x1C, 0xA6, 0xB4, 0xC6, 0xE8, 0xDD, 0x74, 0x1F, 0x4B, 0xBD, 0x8B, 0x8A,
        0x70, 0x3E, 0xB5, 0x66, 0x48, 0x03, 0xF6, 0x0E, 0x61, 0x35, 0x57, 0xB9, 0x86, 0xC1, 0x1D, 0x9E,
        0xE1, 0xF8, 0x98, 0x11, 0x69, 0xD9, 0x8E, 0x94, 0x9B, 0x1E, 0x87, 0xE9, 0xCE, 0x55, 0x28, 0xDF,
        0x8C, 0xA1, 0x89, 0x0D, 0xBF, 0xE6, 0x42, 0x68, 0x41, 0x99, 0x2D, 0x0F, 0xB0, 0x54, 0xBB, 0x16
      ].freeze

      RCON = [0x8D, 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1B, 0x36].freeze

      NK = 4
      NR = 10
      KEY_EXP_SIZE = 176
      KEY_SIZE = 16
      IV_SIZE = 16
      BLOCKLEN = 16

      def self.rotr8(x, n)
        ((x >> n) | (x << (8 - n))) & 0xFF
      end

      # key: 16-byte Array -> 176-byte round-key schedule Array.
      def self.key_expansion(key)
        round_key = Array.new(KEY_EXP_SIZE, 0)
        NK.times { |i| 4.times { |b| round_key[(i * 4) + b] = key[(i * 4) + b] } }

        tempa = [0, 0, 0, 0]
        (NK...(4 * (NR + 1))).each do |i|
          k = (i - 1) * 4
          tempa[0] = round_key[k + 0]
          tempa[1] = round_key[k + 1]
          tempa[2] = round_key[k + 2]
          tempa[3] = round_key[k + 3]

          if (i % NK) == 0
            u8tmp = tempa[0]
            tempa[0] = tempa[1]
            tempa[1] = tempa[2]
            tempa[2] = tempa[3]
            tempa[3] = u8tmp

            # The WOLF-specific step (see module comment): NOT the
            # textbook `SubWord; ^= Rcon` on all four bytes.
            tempa[0] = SBOX[tempa[0]] ^ RCON[i / NK]
            tempa[1] = SBOX[tempa[1]] >> 4
            tempa[2] = 255 - SBOX[tempa[2]] # ~sbox[...] narrowed to uint8_t
            tempa[3] = rotr8(SBOX[tempa[3]], 7)
          end

          j = i * 4
          k = (i - NK) * 4
          round_key[j + 0] = round_key[k + 0] ^ tempa[0]
          round_key[j + 1] = round_key[k + 1] ^ tempa[1]
          round_key[j + 2] = round_key[k + 2] ^ tempa[2]
          round_key[j + 3] = round_key[k + 3] ^ tempa[3]
        end
        round_key
      end

      def self.add_round_key(state, round, round_key)
        KEY_SIZE.times { |i| state[i] ^= round_key[(round * KEY_SIZE) + i] }
      end

      def self.sub_bytes(state)
        KEY_SIZE.times { |i| state[i] = SBOX[state[i]] }
      end

      def self.shift_rows(state)
        t = state[1]; state[1] = state[5]; state[5] = state[9]; state[9] = state[13]; state[13] = t
        t = state[2]; state[2] = state[10]; state[10] = t
        t = state[6]; state[6] = state[14]; state[14] = t
        t = state[3]; state[3] = state[15]; state[15] = state[11]; state[11] = state[7]; state[7] = t
      end

      def self.xtime(x)
        ((x << 1) ^ (((x >> 7) & 1) * 0x1B)) & 0xFF
      end

      def self.mix_columns(state)
        4.times do |c|
          base = c * 4
          s0 = state[base]
          s1 = state[base + 1]
          s2 = state[base + 2]
          s3 = state[base + 3]
          t = s0
          tmp = s1 ^ s0 ^ s2 ^ s3
          state[base + 0] = (s0 ^ tmp ^ xtime(s1 ^ s0)) & 0xFF
          state[base + 1] = (s1 ^ tmp ^ xtime(s2 ^ s1)) & 0xFF
          state[base + 2] = (s2 ^ tmp ^ xtime(s2 ^ s3)) & 0xFF
          state[base + 3] = (s3 ^ tmp ^ xtime(s3 ^ t)) & 0xFF
        end
      end

      def self.cipher(state, round_key)
        add_round_key(state, 0, round_key)
        (1...NR).each do |round|
          sub_bytes(state)
          shift_rows(state)
          mix_columns(state)
          add_round_key(state, round, round_key)
        end
        sub_bytes(state)
        shift_rows(state)
        add_round_key(state, NR, round_key)
      end

      # CTR-mode keystream XOR, in place. `round_key` is the 176-byte
      # schedule followed by the 16-byte IV (KEY_EXP_SIZE + IV_SIZE == 192
      # bytes total), mirroring `AesRoundKey`/`aesCtrXCrypt`'s own layout
      # (the IV lives inside the same buffer and is incremented in place as
      # the counter). Symmetric: encrypting a plaintext with this function
      # and running it again with a fresh, identically-keyed `round_key`
      # recovers the plaintext -- used both to decrypt real data and to
      # build the synthetic protected fixture the test suite round-trips.
      def self.ctr_xcrypt!(data, round_key)
        iv = round_key[KEY_EXP_SIZE, IV_SIZE]
        bi = BLOCKLEN
        state = nil
        data.size.times do |i|
          if bi == BLOCKLEN
            state = iv.dup
            cipher(state, round_key)

            bi = BLOCKLEN - 1
            while bi >= 0
              if iv[bi] == 0xFF
                iv[bi] = 0
                bi -= 1
                next
              end
              iv[bi] += 1
              break
            end
            bi = 0
          end
          data[i] ^= state[bi]
          bi += 1
        end
        data
      end
    end

    # ---------------------------------------------------------------------
    # v3.5 "Pro" decryption (`WolfDataDecrypt.hpp`'s `v3_5::decryptData`).
    #
    # Per known file type: the hardcoded SHA-512 static salt, the plain-file
    # magic/indicator prefix a decrypted file is rewritten to start with
    # (`WolfDataDecrypt.hpp`'s own `PRO_MAGIC` table), and the 3 header-byte
    # indices the ProV3P1 keystream is seeded from (`{0,3,9}` for everything
    # except Game.dat's own `{0,8,6}` -- coincidentally the exact same
    # indices `GameDat::SEEDS`/`Database::SEEDS` already use for the
    # unrelated v2 XOR scheme in `data.rb`, per `FileCoder.hpp`'s
    # `decryptV3_1`/`v2_0` seed wiring, not a coincidence this file invents).
    # `Wolf::FileType::MAP` deliberately has no entry: `WolfDataDecrypt.hpp`
    # itself has none either (`PRO_MAGIC.at(WolfFileType::Map)` would throw)
    # -- even the reference implementation cannot decrypt a Pro-protected
    # map, so this reader does not claim to either.
    module FileType
      GAME_DAT = :game_dat
      COMMON_EVENT = :common_event
      DATA_BASE = :data_base
      TILE_SET_DATA = :tile_set_data
      # Deliberately absent from `PRO_MAGIC` below -- see this file's header.
      # Passed by `Map#initialize` only so `decrypt_v35`'s "no key schedule"
      # error names the file type instead of saying "nil".
      MAP = :map
    end

    PRO_MAGIC = {
      FileType::GAME_DAT => {
        static_salt: "basicD1".bytes,
        magic: [0x00, 0x57, 0x00, 0x00, 0x4F, 0x4C, 0x00, 0x46, 0x4D, 0x55],
        seeds: [0, 8, 6]
      },
      FileType::COMMON_EVENT => {
        static_salt: "Commo2".bytes,
        magic: [0x00, 0x57, 0x00, 0x00, 0x4F, 0x4C, 0x55, 0x46, 0x43, 0x00],
        seeds: [0, 3, 9]
      },
      FileType::DATA_BASE => {
        static_salt: "DBase4".bytes,
        magic: [0x00, 0x57, 0x00, 0x00, 0x4F, 0x4C, 0x55, 0x46, 0x4D, 0x00],
        seeds: [0, 3, 9]
      },
      FileType::TILE_SET_DATA => {
        static_salt: "TilesetA".bytes,
        magic: [0x00, 0x57, 0x00, 0x00, 0x4F, 0x4C, 0x55, 0x46, 0x4D, 0x00],
        seeds: [0, 3, 9]
      }
    }.freeze

    # `wolf::crypt::xorshift32`'s one transform step (state ^= state<<11;
    # ^= state>>19; ^= state<<7), *not* including its C++ static-local-state
    # convenience -- `decrypt_pro_v3_p1!` below is the only caller, and it
    # only ever needs a single step applied to an explicit seed.
    def self.xorshift32_step(state)
      state &= 0xFFFF_FFFF
      state = (state ^ ((state << 0xB) & 0xFFFF_FFFF)) & 0xFFFF_FFFF
      state ^= (state >> 0x13)
      (state ^ ((state << 0x7) & 0xFFFF_FFFF)) & 0xFFFF_FFFF
    end

    # `wolf::crypt::rng::msvc_rand`'s non-Windows fallback (an MSVC-`rand()`
    # clone: LCG with multiplier 214013 / increment 2531011, top of the
    # 15-bit result taken from bits 16..30 of the 32-bit state) -- the exact
    # same LCG constants `Wolf::Crypt.v2` already uses for the unrelated v2.x
    # XOR scheme, just returning the whole 15-bit value here rather than
    # v2's 3 top bits. Returns [rand_value, new_state].
    def self.msvc_rand_next(state)
      state = ((state * 214_013) + 2_531_011) & 0xFFFF_FFFF
      [(state >> 16) & 0x7FFF, state]
    end

    # Arithmetic (sign-extending) right shift of a 32-bit *signed* value,
    # represented throughout as its unsigned 0..0xFFFF_FFFF bit pattern:
    # for a negative pattern (top bit set), the arithmetically-shifted
    # result is exactly `floor(signed_value / 2**n)` -- two's complement
    # arithmetic shift is defined to round toward negative infinity, which
    # is exactly what Ruby's integer `/` already does for a negative
    # dividend, so no bit-twiddling mask is needed.
    def self.arith_shr32(v, n)
      return v >> n if v < 0x8000_0000
      ((v - 0x1_0000_0000) / (2**n)) & 0xFFFF_FFFF
    end

    # C++'s truncating (round-toward-zero) `%`, as opposed to Ruby's own
    # floored `%` -- needed once below where the reference keeps `rn` as a
    # signed `int32_t` right before `% 0xF9`.
    def self.cpp_mod(a, m)
      a < 0 ? -((-a) % m) : a % m
    end

    # `wolf::crypt::datadecrypt::v3_5::decryptProV3P1`: an ad hoc keystream
    # (one `xorshift32` step to seed a *different*, hand-rolled 32-bit
    # mixing function that is iterated per byte) XORed over `data[0xA..]`,
    # in place. `data` is a byte String (the whole protected file --
    # possibly several hundred KB, e.g. a real CommonEvent.dat, so this
    # walks it with `getbyte`/`setbyte` one byte at a time rather than
    # building an `Array` the size of the file; see this gem's own
    # portability note above). `seed_idx` is the 3 header byte offsets
    # (see `PRO_MAGIC`).
    def self.decrypt_pro_v3_p1!(data, seed_idx)
      seed = ((0xB << 24) | (data.getbyte(seed_idx[0]) << 16) | (data.getbyte(seed_idx[1]) << 8) | data.getbyte(seed_idx[2])) & 0xFFFF_FFFF
      rn = xorshift32_step(seed)

      n = data.bytesize
      i = 0xA
      while i < n
        shl15 = (rn << 0xF) & 0xFFFF_FFFF
        shr21 = arith_shr32(shl15 ^ rn, 0x15)
        v1 = (shr21 ^ shl15 ^ rn) & 0xFFFF_FFFF

        rn = (((v1 << 0x9) & 0xFFFF_FFFF) ^ v1) & 0xFFFF_FFFF

        rn_signed = rn >= 0x8000_0000 ? rn - 0x1_0000_0000 : rn
        # `data[i] ^= rn % 0xF9` in C++ only ever consumes the *low byte* of
        # the (possibly negative) `int` result once narrowed back to
        # `uint8_t` -- Ruby's `% 256` on a value already reduced to
        # (-0xF8..0xF8) by `cpp_mod` reproduces that two's-complement byte
        # exactly, whether the mod result was negative or not.
        data.setbyte(i, data.getbyte(i) ^ (cpp_mod(rn_signed, 0xF9) % 256))
        i += 1
      end
      data
    end

    KEY_START_OFFSET = 12
    IV_START_OFFSET = 73
    AES_DATA_OFFSET = 20
    # 15-byte plain header + 128-byte encrypted-key block WolfTL's own
    # comment describes it as; discarded wholesale once decrypted (it is
    # filler the editor writes, not real file content -- see this file's
    # header for what replaces it).
    PRO_SPECIAL_SIZE = 143

    def self.pro_magic_for(file_type)
      PRO_MAGIC[file_type] || raise(
        Wolf::Error,
        "Pro-protected data (v3.5 AES scheme), but this reader has no key " \
        "schedule for file type #{file_type.inspect} -- WolfTL's own reference " \
        "implementation does not either (no PRO_MAGIC entry), so this is refused " \
        "rather than guessed at"
      )
    end

    # `buffer[AES_DATA_OFFSET, aes_size)` is the region `aesCtrXCrypt` runs
    # over -- capped, for a large file, to a small `msvc_rand`-derived range
    # (200..325) rather than the whole tail (`WolfDataDecrypt.hpp`'s own
    # comment: "¯\_(ツ)_/¯ that's what the code says (probably) and it
    # works ¯\_(ツ)_/¯" -- kept verbatim here, since this reader has no
    # better explanation for it either). Shared between `decrypt_v35` and
    # the fixture-building `encrypt_v35` below so the cap logic -- easy to
    # get subtly wrong once, let alone twice -- exists exactly once.
    # `buffer[12]` must already be in its post-`decrypt_pro_v3_p1!` state
    # (true of both callers: decrypting reads it after that step already
    # ran; encrypting seeds `buffer[12]` itself, so it holds that value
    # from the start -- see `encrypt_v35`'s own comment).
    def self.aes_size_for(buffer)
      state = buffer.getbyte(12)
      aes_size = buffer.bytesize - AES_DATA_OFFSET
      r1, state = msvc_rand_next(state)
      if aes_size >= ((r1 % 126) + 200)
        r2, = msvc_rand_next(state)
        new_size = (r2 % 126) + 200
        aes_size = new_size if aes_size > new_size
      end
      aes_size
    end

    # The AES-128 round-key schedule (176-byte key expansion + 16-byte IV)
    # for `buffer`, per `info`'s static salt -- shared between `decrypt_v35`
    # and `encrypt_v35` for the same reason `aes_size_for` is.
    def self.round_key_for(buffer, info)
      dyn_salt = Sha512.calc_dyn_salt(buffer)
      salted_pwd = Sha512.salt_password([], dyn_salt, info[:static_salt])
      hash_hex = Sha512.hexdigest(salted_pwd)
      aes_key = hash_hex[KEY_START_OFFSET, Aes::KEY_SIZE].bytes
      aes_iv = hash_hex[IV_START_OFFSET, Aes::IV_SIZE].bytes
      Aes.key_expansion(aes_key) + aes_iv
    end

    # `region_xcrypt` runs `Aes.ctr_xcrypt!` (an `Array`-in-place API) over
    # a *slice* of `buffer` (a byte String) and splices the result back in
    # -- shared by `decrypt_v35` and `encrypt_v35`. Safe against mruby's
    # `Array` length cap despite `buffer` itself being file-sized: `size`
    # here is always `aes_size_for`'s result, which is never more than 325
    # bytes (see `aes_size_for`'s own comment) regardless of how large
    # `buffer` is, so the `Array` this ever builds is always small.
    def self.region_xcrypt(buffer, offset, size, round_key)
      region = buffer.byteslice(offset, size).bytes
      Aes.ctr_xcrypt!(region, round_key)
      buffer.byteslice(0, offset) + region.pack("C*") + buffer.byteslice(offset + size, buffer.bytesize - offset - size)
    end

    # Decrypts a v3.5 Pro-protected file's bytes (a byte String, *including*
    # the 0x50 marker byte) for the given `FileType`. Returns a new byte
    # String shaped exactly like a plain, never-protected, UTF-8 file: a
    # 1-byte 0 "not v2-encrypted" indicator, the file's own magic, and a
    # trailing UTF8_MARK byte, followed by the real (now-decrypted) body --
    # i.e. exactly what `Wolf.open_envelope`'s "not encrypted" branch and
    # `Wolf.read_magic` already expect, so nothing downstream needs to know
    # decryption happened at all. Raises `Wolf::Error` for a file type this
    # reader has no static salt for (`FileType::MAP`, or anything else not
    # in `PRO_MAGIC` -- see this file's header for why Map is out of scope).
    def self.decrypt_v35(data, what, file_type)
      if data.bytesize < PRO_SPECIAL_SIZE
        raise Wolf::Error, "#{what}: Pro-protected data is too small (#{data.bytesize} < #{PRO_SPECIAL_SIZE})"
      end

      info = pro_magic_for(file_type)

      buffer = data.dup
      decrypt_pro_v3_p1!(buffer, info[:seeds])

      aes_size = aes_size_for(buffer)
      round_key = round_key_for(buffer, info)
      buffer = region_xcrypt(buffer, AES_DATA_OFFSET, aes_size, round_key)

      info[:magic].pack("C*") + buffer.byteslice(PRO_SPECIAL_SIZE, buffer.bytesize - PRO_SPECIAL_SIZE)
    end

    # The inverse of `decrypt_v35` -- **test/fixture use only**, the same
    # role `Wolf::DataWolf.pack` plays for the Data.wolf archive format
    # (ADR 0093): builds a synthetic v3.5 Pro-protected buffer whose
    # plaintext (`header10 ++ junk1_10 ++ junk2_123 ++ plain_body`, laid out
    # at offsets 0, 10, 20 and 143) `decrypt_v35` recovers as exactly
    # `PRO_MAGIC[file_type][:magic] + plain_body` -- the leading 143 bytes
    # are discarded either way, per `decrypt_v35`'s own contract, so only
    # `plain_body` (offset 143 on) ever shows up in the decrypted result.
    # No released game ever needs this: real Pro-protected files come from
    # the actual editor, not from this reader.
    #
    # `header10` must have `[1] == 0x50` and `[5] >= 0x57` (else
    # `Crypt.protected?`/`decrypt_v35` itself would not recognize the
    # result as v3.5 data) and its `info[:seeds]` indices are free to pick
    # (`decrypt_pro_v3_p1!` only ever reads them, from the *same* indices
    # in both the plaintext and the ciphertext, since neither the AES step
    # -- offset 20 on -- nor this XOR step's own seeding -- offset < 10 --
    # touches them). Offsets 11..14 (i.e. `junk1_10[1..4]`) feed
    # `Sha512.calc_dyn_salt` and offset 12 (`junk1_10[2]`) seeds
    # `aes_size_for`; both are read here from the *plaintext* buffer,
    # matching exactly what `decrypt_v35` itself ends up reading them as
    # (see `aes_size_for`'s own comment) -- the reason this exists as a
    # real, shared helper rather than two independently-hand-derived
    # implementations.
    #
    # `header10`/`junk1_10`/`junk2_123` are small, fixed-size Arrays (10, 10
    # and 123 bytes); `plain_body` is a byte String, not an Array -- it is
    # the one part of this that can be file-sized (a real CommonEvent.dat
    # easily exceeds mruby's `Array` length cap), so it is only ever handled
    # as a String, the same discipline `decrypt_v35`/`region_xcrypt` follow.
    def self.encrypt_v35(plain_body, file_type, header10:, junk1_10:, junk2_123:)
      info = pro_magic_for(file_type)
      plain = (header10 + junk1_10 + junk2_123).pack("C*") + plain_body

      aes_size = aes_size_for(plain)
      round_key = round_key_for(plain, info)
      cipher = region_xcrypt(plain, AES_DATA_OFFSET, aes_size, round_key)

      decrypt_pro_v3_p1!(cipher, info[:seeds])
      cipher
    end

    # The one seam every Pro-protection-aware caller in `data.rb` goes
    # through (mirroring how `Wolf::Project#read` picked a backing store
    # through one seam for the Data.wolf PR, ADR 0093): returns `data`
    # (a byte String) unchanged when it is not Pro-protected at all, the
    # decrypted replacement (also a byte String, ready for `open_envelope`)
    # for a v3.5 file this reader supports, and raises a specific,
    # version-named `Wolf::Error` for v3.1/v3.3 or an unsupported file type.
    def self.decrypt_protected(data, what, file_type)
      return data unless protected?(data)

      crypt_version = data.getbyte(5)
      if crypt_version.nil?
        raise Error, "#{what}: truncated Pro-protection header"
      elsif crypt_version < 0x55
        raise Error,
              "#{what} is Pro-protected with the v3.1 scheme (cryptVersion " \
              "#{sprintf('0x%02x', crypt_version)}); WolfTL's own reference " \
              "implementation never implemented a decrypt function for it either " \
              "(see wolf_crypt_pro.rb's file header), so this reader refuses rather " \
              "than guessing"
      elsif crypt_version < 0x57
        raise Error,
              "#{what} is Pro-protected with the v3.3 scheme (cryptVersion " \
              "#{sprintf('0x%02x', crypt_version)}); its key derivation is a large " \
              "custom PRNG state machine this reader did not port with enough " \
              "confidence to ship (see wolf_crypt_pro.rb's file header), so this is " \
              "refused rather than risking a silently-wrong decrypt"
      else
        decrypt_v35(data, what, file_type)
      end
    end
  end
end
