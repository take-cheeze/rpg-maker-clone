- **A weapon whose 命中率 (hit rate) was never hand-tuned in the editor now
  actually lands hits.** The item schema defaulted an omitted `hit` field
  (chunk 0x11) to 0, following the community analysis notes' blanket
  omitted-value guess for `ber` fields. Real Nepheshel data contradicts that
  guess: 76 of its 104 weapons — the ordinary ones, ショートソード (Short
  Sword) included — omit the field entirely, and every attack with such a
  weapon rolled against a 0% base hit chance and always missed. The default
  is now 90, RPG2000's own baseline hit rate already used elsewhere as the
  unarmed/no-weapon fallback and the default enemy rate; no weapon in
  Nepheshel ever writes 90 explicitly, which is what an implicit default
  looks like.
