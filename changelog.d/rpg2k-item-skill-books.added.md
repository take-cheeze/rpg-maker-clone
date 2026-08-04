- RPG Maker 2000 item menu: **skill books** (database item type 7) are now usable
  alongside medicines. Choosing a book prompts for an ally, and — if that ally
  does not already know it — teaches the skill in the book's `skill_id` field
  (53) and consumes one book; a book used on someone who already knows the skill
  is reported and consumed nothing. `Game::Party#use_item` now dispatches on the
  item type (`use_medicine` / `use_skill_book`), and `field_usable?` /
  `item_effective?` account for books, with three new checks in
  `scripts/rpg2k_logic_check.rb`. `Scene::ItemMenu` routes books through the
  existing single-target picker (only an all-ally medicine still skips it). Seed
  (type 8, permanent stat boost) and switch (type 9) item use remain follow-ups.
