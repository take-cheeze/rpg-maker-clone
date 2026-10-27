# Remembering the arm of a table row (SPLAT_ROW_MEMO)

`send(*TABLE[i])` on self compiles to the guarded splat send (COMPUTED_SEND_GUARDED, see
`docs/bc2cpp-dynamic-site-census.md`). With SPLAT_SHARED the list is read in place, but each call still pays
for all of this:

- a scan proving that every element is an immediate;
- a switch on the length;
- a Symbol-to-arm table load;
- a second switch on the arm.

Optcarrot's `CPU#run` does this once per emulated instruction (`send(*DISPATCH[@opcode])`).

SPLAT_ROW_MEMO gives such a site a memo of 256 entries, indexed by `i`. An entry holds a copy of a list whose
elements were all immediates when its arm was found, together with that arm's number. On a call with a Fixnum
`i` in range and an Array list, the list is compared word by word with the entry's copy. If they are equal, the
site switches straight on the stored arm and reads the arguments from the copy. Otherwise, or when `i` is out of
range, the site takes the length and Symbol tables as before, and refills the entry when the list qualifies.

## Why no proof about the table is needed

The arm depends only on the list's length and its leading Symbol. Two lists that are equal bit for bit have the
same length and the same immediates, so they select the same arm and pass the same arguments. The index only
chooses which entry to compare, so the memo does not depend on what the table holds. All of these just miss and
refill:

- a table whose rows are not frozen (optcarrot's `DISPATCH` rows are built by `CPU.op`, never frozen);
- a row written in place;
- a reassigned outer slot;
- a second table read at the same index;
- a Hash table.

The copy holds immediates only, so it needs no GC root. A row that later gains an object stops matching, because
an object's word is never an immediate's word.

## What stays as it was

- The arms. They are the same direct calls with the same guards, so a subclass that redefines a target still takes
  its own method.
- A list without a `GETIDX` straight before the shared pair (`send(*list)`). It keeps the tables alone.
- The fallback. Every list that no arm takes gets ARYCAT's copy and the original `send`.

An arm reads its arguments into locals before it calls the target. A call that re-enters the site and refills the
same entry therefore cannot change them.

`BC2CPP_SPLAT_ROW_MEMO=0` turns the memo off, for comparison.

## Check

`MRBC=path/to/mrbc ruby scripts/bc2cpp/splat_row_memo_check.rb` checks the generated code: which sites get the
memo, the bit compare, and the kill switch. It also runs a fixture interpreted and compiled and compares the
output. The fixture covers frozen and unfrozen rows, rows edited in place (name, argument, length), replaced outer
slots, a shared index across two tables, a Hash table, object and Float elements under `GC.stress`, indices that
are out of range, negative or past the memo, non-Integer indices, a subclass override, and a re-entrant arm.

## Effect on optcarrot

Measured with callgrind on the probe (Lan_Master, instructions per frame taken from the 21-frame minus 1-frame
runs), against the same tree built with `BC2CPP_SPLAT_ROW_MEMO=0`:

| | memo off | memo on |
| --- | ---: | ---: |
| frame loop, all functions | 29.70M | 29.53M |
| `CPU#run` | 1.630M | 1.465M |
| startup (1-frame run) | 1,104.2M | 1,104.1M |

That is about 17 instructions saved per emulated instruction. The checksum stays 59662 at 180 frames. What remains
on a hit is the index and Array tests, the length and pointer loads, a compare per element and the switch. Taking
the arm by row identity alone would also drop the compares, but it needs proof that no row is ever written. That
proof is not made here.
