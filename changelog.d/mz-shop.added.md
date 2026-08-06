- **MZ can buy something.** `--mz_shop_test` (`MZ_MODE=shop`) opens a shop from
  the map with a Shop Processing command, taps confirm through Buy, the goods
  list and the quantity window, and asserts both that the gold left the purse
  and that the item arrived — either alone passes on a broken shop, since gold
  can leave without goods arriving and goods can arrive without being paid for.
  `Scene_Shop` is a whole scene nothing else here enters, and the only place the
  engine spends gold against a price list.
