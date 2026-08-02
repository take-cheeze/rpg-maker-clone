# Tests for the MV JavaScript host environment (milestone M3): the persistent
# context, the browser-global aliases, console, and the synchronous
# XMLHttpRequest backed by the native file reader. These run in the full test
# binary where the gem's C++ (quickjs-ng) is compiled in.

assert 'MV host aliases window/self/global to the global object' do
  assert_equal true, MV::JS.eval("window === globalThis")
  assert_equal true, MV::JS.eval("self === globalThis")
  assert_equal true, MV::JS.eval("global === globalThis")
end

assert 'MV host provides a console that does not throw' do
  assert_nil MV::JS.eval("console.log('mv host log'); console.warn('w'); undefined")
end

assert 'MV host state persists across evals (one shared context)' do
  MV::JS.eval("globalThis.__mv_probe = 41")
  assert_equal 42, MV::JS.eval("globalThis.__mv_probe + 1")
end

assert 'MV host XMLHttpRequest reads a local file synchronously' do
  path = "mvjs_xhr_fixture.json"
  File.open(path, "w") { |f| f.write('{"gameTitle":"Test MV","ok":true}') }
  begin
    title = MV::JS.eval("var x=new XMLHttpRequest(); x.open('GET','#{path}'); x.send(); JSON.parse(x.responseText).gameTitle")
    assert_equal "Test MV", title
    status = MV::JS.eval("var s=new XMLHttpRequest(); s.open('GET','#{path}'); s.send(); s.status")
    assert_equal 200, status
  ensure
    File.delete(path) rescue nil
  end
end

assert 'MV host XMLHttpRequest reports status 404 for a missing file' do
  status = MV::JS.eval("var x=new XMLHttpRequest(); x.open('GET','definitely_missing_mv_file.json'); x.send(); x.status")
  assert_equal 404, status
end

assert 'MV::JS.base_dir roots game-relative asset paths' do
  path = "mvjs_base_probe.json"
  File.open(path, "w") { |f| f.write('{"v":7}') }
  begin
    # With no base dir, a bare relative path resolves from the cwd and is found.
    MV::JS.base_dir = ""
    ok = MV::JS.eval("var x=new XMLHttpRequest(); x.open('GET','#{path}'); x.send(); x.status")
    assert_equal 200, ok
    # Setting a base dir prefixes bare paths, so the same name now resolves
    # under it and misses (proving the rooting is applied)...
    MV::JS.base_dir = "no_such_dir"
    missed = MV::JS.eval("var y=new XMLHttpRequest(); y.open('GET','#{path}'); y.send(); y.status")
    assert_equal 404, missed
    # ...while a path already rooted at the base dir is not prefixed twice.
    MV::JS.base_dir = "."
    v = MV::JS.eval("var z=new XMLHttpRequest(); z.open('GET','./#{path}'); z.send(); JSON.parse(z.responseText).v")
    assert_equal 7, v
  ensure
    MV::JS.base_dir = ""
    File.delete(path) rescue nil
  end
end

assert 'MV host XMLHttpRequest fires onload with the response text' do
  path = "mvjs_xhr_onload.json"
  File.open(path, "w") { |f| f.write('[1,2,3]') }
  begin
    sum = MV::JS.eval("var got=null; var x=new XMLHttpRequest(); x.onload=function(){got=JSON.parse(x.responseText)}; x.open('GET','#{path}'); x.send(); got[0]+got[1]+got[2]")
    assert_equal 6, sum
  ensure
    File.delete(path) rescue nil
  end
end

assert 'MV host setTimeout fires from pump only once its delay elapses' do
  MV::JS.eval("globalThis.__to = 0; setTimeout(function(){ globalThis.__to = 7; }, 100);")
  MV::JS.pump(50.0)  # not due yet
  assert_equal 0, MV::JS.eval("globalThis.__to")
  MV::JS.pump(150.0) # due
  assert_equal 7, MV::JS.eval("globalThis.__to")
end

assert 'MV host clearTimeout cancels a pending timer' do
  MV::JS.eval("globalThis.__ct = 0; globalThis.__id = setTimeout(function(){ globalThis.__ct = 1; }, 10); clearTimeout(globalThis.__id);")
  MV::JS.pump(100.0)
  assert_equal 0, MV::JS.eval("globalThis.__ct")
end

assert 'MV host requestAnimationFrame runs once per pump' do
  MV::JS.eval("globalThis.__raf = 0; requestAnimationFrame(function(){ globalThis.__raf++; });")
  MV::JS.pump(16.0)
  assert_equal 1, MV::JS.eval("globalThis.__raf")
  MV::JS.pump(32.0)  # not re-queued
  assert_equal 1, MV::JS.eval("globalThis.__raf")
end

assert 'MV host drains promise microtasks on pump' do
  MV::JS.eval("globalThis.__pr = 0; Promise.resolve().then(function(){ globalThis.__pr = 5; });")
  MV::JS.pump(0.0)
  assert_equal 5, MV::JS.eval("globalThis.__pr")
end

assert 'MV host provides a silent AudioContext stub (needed by initAudio)' do
  assert_equal true, MV::JS.eval("typeof AudioContext === 'function'")
  assert_equal true, MV::JS.eval("typeof webkitAudioContext === 'function'")
  assert_equal "running", MV::JS.eval("new AudioContext().state")
  # The gain/buffer-source graph nodes MV's WebAudio wires up must be connectable.
  assert_equal "function", MV::JS.eval("typeof new AudioContext().createGain().connect")
  assert_equal "function", MV::JS.eval("typeof new AudioContext().createBufferSource().start")
end

assert 'MV host provides navigator/location/performance' do
  assert_equal "string", MV::JS.eval("typeof navigator.userAgent")
  assert_equal "string", MV::JS.eval("typeof location.href")
  assert_equal "number", MV::JS.eval("typeof performance.now()")
end

assert 'MV host localStorage stores and retrieves values in memory' do
  MV::JS.eval("localStorage.setItem('save1', 'data')")
  assert_equal "data", MV::JS.eval("localStorage.getItem('save1')")
  assert_nil MV::JS.eval("localStorage.getItem('missing')")
  MV::JS.eval("localStorage.removeItem('save1')")
  assert_nil MV::JS.eval("localStorage.getItem('save1')")
end

assert 'MV host require("path") provides join/dirname/basename/extname' do
  assert_equal "a/b/c", MV::JS.eval("require('path').join('a','b','c')")
  assert_equal "a/b", MV::JS.eval("require('path').dirname('a/b/c.json')")
  assert_equal "c.json", MV::JS.eval("require('path').basename('a/b/c.json')")
  assert_equal ".json", MV::JS.eval("require('path').extname('a/b/c.json')")
end

assert 'MV host require("fs") reads, writes and checks files (save path)' do
  path = "mvjs_fs_save.txt"
  File.delete(path) rescue nil
  begin
    assert_equal false, MV::JS.eval("require('fs').existsSync('#{path}')")
    MV::JS.eval("require('fs').writeFileSync('#{path}', 'saved-data')")
    assert_equal true, MV::JS.eval("require('fs').existsSync('#{path}')")
    assert_equal true, File.exist?(path)
    assert_equal "saved-data", MV::JS.eval("require('fs').readFileSync('#{path}', 'utf8')")
  ensure
    File.delete(path) rescue nil
  end
end

assert 'MV host require rejects unknown modules' do
  assert_raise(RuntimeError) { MV::JS.eval("require('no_such_module')") }
end

assert 'MV::JS.eval_file evaluates a script file in the shared host context' do
  path = "mvjs_script.js"
  File.open(path, "w") { |f| f.write("globalThis.__fromFile = 40 + 2;") }
  begin
    MV::JS.eval_file(path)
    assert_equal 42, MV::JS.eval("globalThis.__fromFile")
  ensure
    File.delete(path) rescue nil
  end
end

assert 'MV::JS.eval_file raises for a missing file' do
  assert_raise(RuntimeError) { MV::JS.eval_file("definitely_missing_script.js") }
end
