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
