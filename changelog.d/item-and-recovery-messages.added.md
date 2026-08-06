- **A potion says what it did.** An item borrows the `use_item` term rather than
  carrying a sentence of its own, and it is the one battle line RPG2000 builds
  from two names — 「リトはポーションを使った！」 is the caster, は, the item and
  the term. What a heal restored now reads in the game's own words too
  (「リトのＨＰが 30 回復した！」), which the skill sentences left blank: a working
  recovery printed its skill line and then nothing. The pool name comes from the
  用語 `hp` / `mp` field rather than a literal — Nepheshel writes them full-width
  as ＨＰ / ＭＰ and mtf-meido-action as HP / MP, so a hard-coded "HP" would be
  wrong in exactly one of the two test beds — and a heal that filled both pools
  says so once per pool. An item that did nothing keeps the composed wording,
  since unlike a skill it has no `failure_message` to pick a sentence with. The
  battle log's only remaining invention is the critical-hit line. See the second
  addendum to ADR 0036.
