# Tests for the embedded JavaScript engine (MV::JS, milestone M2). These run in
# the full test binary, where the gem's C++ (quickjs-ng) is compiled in, and
# prove JavaScript can be evaluated and its scalar results marshalled to mruby.

assert 'MV::JS.eval evaluates arithmetic to an Integer' do
  assert_equal 3, MV::JS.eval("1 + 2")
end

assert 'MV::JS.eval returns a Float for non-integral numbers' do
  assert_equal 0.5, MV::JS.eval("1 / 2")
end

assert 'MV::JS.eval marshals strings' do
  assert_equal "rpgmaker", MV::JS.eval("'rpg' + 'maker'")
end

assert 'MV::JS.eval marshals booleans and null/undefined' do
  assert_equal true, MV::JS.eval("1 < 2")
  assert_equal false, MV::JS.eval("1 > 2")
  assert_nil MV::JS.eval("null")
  assert_nil MV::JS.eval("undefined")
end

assert 'MV::JS.eval runs a small stateful program' do
  assert_equal 15, MV::JS.eval("var t = 0; for (var i = 1; i <= 5; i++) t += i; t;")
end

assert 'MV::JS.eval raises on a JavaScript exception' do
  assert_raise(RuntimeError) { MV::JS.eval("throw new Error('boom')") }
end
