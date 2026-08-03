# Tests for the input bridge (milestone M5): RGSS::Input (fed by the SDL/
# terminal backends) mapped onto MV's virtual buttons and pushed into MV's
# `Input._currentState`, which its scenes read for navigation/confirm/cancel.

assert 'MV maps RGSS input keys to MV virtual buttons' do
  # Start from a clean slate so unrelated state can't leak in.
  [RGSS::Input::C, RGSS::Input::B, RGSS::Input::UP, RGSS::Input::DOWN,
   RGSS::Input::LEFT, RGSS::Input::RIGHT].each { |k| RGSS::Input.release(k) }

  RGSS::Input.press(RGSS::Input::C)     # confirm -> ok
  RGSS::Input.press(RGSS::Input::UP)    # -> up
  buttons = MV.pressed_buttons
  assert_equal true, buttons.include?("ok")
  assert_equal true, buttons.include?("up")
  assert_equal false, buttons.include?("down")
  # B is the cancel/menu key; MV has no separate 'cancel', so it maps to escape.
  assert_equal false, buttons.include?("escape")

  RGSS::Input.press(RGSS::Input::B)
  assert_equal true, MV.pressed_buttons.include?("escape")

  RGSS::Input.release(RGSS::Input::C)
  RGSS::Input.release(RGSS::Input::UP)
  RGSS::Input.release(RGSS::Input::B)
  assert_equal false, MV.pressed_buttons.include?("ok")
end

assert 'MV pushes held buttons into Input._currentState (and clears released)' do
  # A minimal stand-in for MV's Input; sync fills the field the engine reads.
  MV::JS.eval("globalThis.Input = { _currentState: {} };")
  begin
    RGSS::Input.press(RGSS::Input::C)
    RGSS::Input.press(RGSS::Input::DOWN)
    assigns = MV.pressed_buttons.map { |b| "c['#{b}']=true;" }.join
    MV::JS.eval(
      "(function(){ var c = Input._currentState; for (var k in c) c[k] = false; " \
      "#{assigns} })();"
    )
    assert_equal true, MV::JS.eval("!!Input._currentState.ok")
    assert_equal true, MV::JS.eval("!!Input._currentState.down")
    assert_equal false, MV::JS.eval("!!Input._currentState.up")

    # Only held buttons stay set: releasing clears them on the next push.
    RGSS::Input.release(RGSS::Input::C)
    RGSS::Input.release(RGSS::Input::DOWN)
    assigns = MV.pressed_buttons.map { |b| "c['#{b}']=true;" }.join
    MV::JS.eval(
      "(function(){ var c = Input._currentState; for (var k in c) c[k] = false; " \
      "#{assigns} })();"
    )
    assert_equal false, MV::JS.eval("!!Input._currentState.ok")
    assert_equal false, MV::JS.eval("!!Input._currentState.down")
  ensure
    MV::JS.eval("delete globalThis.Input;")
  end
end

assert 'MV movement probe cycles direction every dwell window' do
  # The --mv_move_test probe holds down, then right, then up, then left (each for
  # MOVE_PROBE_DWELL frames) so some open direction moves the player on any map.
  d = MV::MOVE_PROBE_DWELL
  assert_equal RGSS::Input::DOWN, MV.move_probe_dir(0)
  assert_equal RGSS::Input::DOWN, MV.move_probe_dir(d - 1)
  assert_equal RGSS::Input::RIGHT, MV.move_probe_dir(d)
  assert_equal RGSS::Input::UP, MV.move_probe_dir(2 * d)
  assert_equal RGSS::Input::LEFT, MV.move_probe_dir(3 * d)
  # Wraps back to down after all four.
  assert_equal RGSS::Input::DOWN, MV.move_probe_dir(4 * d)
end
