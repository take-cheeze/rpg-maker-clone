- **Fixed: encrypted MV/MZ games could not load a single asset.** Most released
  games tick "Encrypt Images" at deployment, and that changes the loading path
  completely — nothing is opened by name. The engine XHRs the file as an
  ArrayBuffer, decrypts it in its own JavaScript, wraps the plaintext in a
  `Blob` and hands `URL.createObjectURL(blob)` to an `Image`. Neither global
  existed in the host and `XMLHttpRequest` ignored `responseType =
  "arraybuffer"`, so the first encrypted asset threw and the boot died in
  `Scene_Boot`: a black screen for every such game. All three are now provided,
  and two real games downloaded from freem — one MV, one MZ — boot from their
  encrypted assets, the MZ one rendering its full title screen.
- **Fixed: XHR callbacks attached after `send()` never fired.** MV's
  `Decrypter.decryptImg` calls `send()` and *then* assigns `onload`, which works
  in a browser because XHR is asynchronous; our synchronous shim had already
  fired. The dispatch now runs inline when a handler is already attached —
  MZ's `DataManager.loadDataFile` depends on that timing, and deferring it
  wholesale threw `$dataMap.width` out of `Game_Map.width()` mid-save — and
  otherwise looks again on the next frame for a handler attached in between.
- **Fixed: the MZ test bed omitted two images `Spriteset_Map` reserves.**
  `img/system/Balloon.png` and `Shadow1.png` were never authored; a missing
  image resolves to a 1x1 transparent bitmap that reports itself loaded, so
  nothing complained. Encrypted, the same absence is a 404, `Bitmap._onError`
  marks the bitmap errored and `ImageManager.isReady()` throws every frame —
  outside any scene update, so nothing logs it — leaving a black, unresponsive
  map. `scripts/mz_testbed_check.rb` also understands encrypted assets now,
  instead of reporting every one of a real game's images as missing.
