# Tests for save persistence (milestone M5): MV saves through localStorage (it
# stays in web-storage mode so its nwjs-only code paths are never taken), and
# our localStorage is backed by a JSON file under the game's save/ dir so saves
# survive across runs.

assert 'MV localStorage persists items to save/websave.json and reads them back' do
  MV::JS.base_dir = "mvjs_save_fixture"
  begin
    MV::JS.eval("localStorage.setItem('RPG File1', 'HELLO'); null")
    # setItem writes through to disk under <base>/save/ (created on demand).
    assert_equal true, MV::JS.eval("__mv_existsSync('save/websave.json')")
    raw = MV::JS.eval("__mv_readFileSync('save/websave.json')")
    assert_equal true, raw.include?("RPG File1")
    assert_equal true, raw.include?("HELLO")
    # Reads back through the API.
    assert_equal "HELLO", MV::JS.eval("localStorage.getItem('RPG File1')")
    # Removal is persisted too.
    MV::JS.eval("localStorage.removeItem('RPG File1'); null")
    assert_nil MV::JS.eval("localStorage.getItem('RPG File1')")
    assert_equal false, MV::JS.eval("__mv_readFileSync('save/websave.json')").include?("HELLO")
  ensure
    File.delete("mvjs_save_fixture/save/websave.json") rescue nil
    Dir.delete("mvjs_save_fixture/save") rescue nil
    Dir.delete("mvjs_save_fixture") rescue nil
    MV::JS.base_dir = ""
  end
end
