# Tests for the pointer bridge (milestone M5): RGSS::Input mouse state (fed by
# the SDL backend) pushed into MV's TouchInput for menu/title clicking.

assert 'MV touch bridge feeds TouchInput press/move/release edges' do
  # Minimal TouchInput stand-in with the fields the bridge drives; _newState is
  # what MV's TouchInput.update consumes.
  MV::JS.eval("globalThis.TouchInput = { _newState: {} };")
  begin
    # First pressed sample: sets position, marks triggered + pressed.
    MV::JS.eval(MV.touch_bridge_js(120, 84, true))
    assert_equal 120, MV::JS.eval("TouchInput._x")
    assert_equal 84, MV::JS.eval("TouchInput._y")
    assert_equal true, MV::JS.eval("!!TouchInput._newState.triggered")
    assert_equal true, MV::JS.eval("!!TouchInput._screenPressed")

    # Held + same/again pressed: a move edge, not another trigger.
    MV::JS.eval("TouchInput._newState = {};")
    MV::JS.eval(MV.touch_bridge_js(122, 84, true))
    assert_equal false, MV::JS.eval("!!TouchInput._newState.triggered")
    assert_equal true, MV::JS.eval("!!TouchInput._newState.moved")

    # Release: a released edge, pressed flags cleared.
    MV::JS.eval("TouchInput._newState = {};")
    MV::JS.eval(MV.touch_bridge_js(122, 84, false))
    assert_equal true, MV::JS.eval("!!TouchInput._newState.released")
    assert_equal false, MV::JS.eval("!!TouchInput._screenPressed")
  ensure
    MV::JS.eval("delete globalThis.TouchInput;")
  end
end

assert 'RGSS::Input exposes pointer state (defaults with no SDL mouse)' do
  # With no SDL backend driving it, the pointer sits at the origin, unpressed.
  assert_equal true, RGSS::Input.mouse_x.is_a?(Integer)
  assert_equal true, RGSS::Input.mouse_y.is_a?(Integer)
  assert_equal false, RGSS::Input.mouse_pressed?
end
