- **A skill announces itself in its own words.** The skill row carries two
  sentences of its own rather than borrowing a 用語 term, and they compose
  differently: `using_message1` follows the caster's name like every other
  predicate, while `using_message2` **stands alone** as a second line — so a
  spell reads 「リトは炎を放った！」 then 「あたりが真っ赤に染まる！」, a caster and
  then a scene. 229 of Nepheshel's 306 skills and 122 of mtf-meido-action's 134
  set the first; 18 set the second. A skill that achieved nothing (a miss, or a
  recovery that restored and cured nothing) takes its own failure sentence
  instead of a damage line, chosen by the row's `failure_message` from the three
  用語 failure lines plus the dodge line at index 3 — all four values are in real
  use across the test beds. A skill row with no sentence keeps the composed
  wording, since the bare damage line would lose the only thing naming what was
  cast. Items still keep theirs: the `use_item` term is a different shape and its
  own change. See the addendum to ADR 0036.
