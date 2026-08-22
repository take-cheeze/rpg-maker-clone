# Tests for the input bridge (milestone M5): RGSS::Input (fed by the SDL/
# terminal backends) mapped onto MV's virtual buttons and pushed into MV's
# `Input._currentState`, which its scenes read for navigation/confirm/cancel.

assert 'MV.confirm_settle_tap presses confirm briefly once per cadence, then releases' do
  RGSS::Input.release(RGSS::Input::C)

  # No tap yet at a frame between cycles.
  MV.confirm_settle_tap(1)
  assert_false MV.pressed_buttons.include?("ok")

  # Pressed at the start of a cycle...
  MV.confirm_settle_tap(0)
  assert_true MV.pressed_buttons.include?("ok")

  # ...held through the frame before CONFIRM_TAP_HOLD...
  MV.confirm_settle_tap(MV::CONFIRM_TAP_HOLD - 1)
  assert_true MV.pressed_buttons.include?("ok")

  # ...and released once CONFIRM_TAP_HOLD is reached.
  MV.confirm_settle_tap(MV::CONFIRM_TAP_HOLD)
  assert_false MV.pressed_buttons.include?("ok")

  # The next cycle (frame == CONFIRM_TAP_EVERY) presses again, so a probe that
  # calls this every frame keeps tapping for as long as the caller drives it.
  MV.confirm_settle_tap(MV::CONFIRM_TAP_EVERY)
  assert_true MV.pressed_buttons.include?("ok")
ensure
  RGSS::Input.release(RGSS::Input::C)
end

assert 'MV.message_busy? tracks $gameMessage.isBusy, and never raises' do
  # Undefined engine global: the move probe's settle window must not hang
  # waiting on a read that can never succeed.
  MV::JS.eval("globalThis.$gameMessage = undefined;")
  assert_false MV.message_busy?

  MV::JS.eval("globalThis.$gameMessage = { isBusy: function(){ return true; } };")
  assert_true MV.message_busy?

  MV::JS.eval("globalThis.$gameMessage = { isBusy: function(){ return false; } };")
  assert_false MV.message_busy?
end

assert 'MV.event_running? tracks $gameMap.isEventRunning, and never raises' do
  # Undefined engine global: the move probe's settle window must not hang
  # waiting on a read that can never succeed.
  MV::JS.eval("globalThis.$gameMap = undefined;")
  assert_false MV.event_running?

  # A page with no $gameMessage traffic at all (Show Picture, Wait, Move
  # Route, ...) still reports busy here even though MV.message_busy? cannot
  # see it -- this is the case #message_busy? alone misses.
  MV::JS.eval("globalThis.$gameMap = { isEventRunning: function(){ return true; } };")
  assert_true MV.event_running?

  MV::JS.eval("globalThis.$gameMap = { isEventRunning: function(){ return false; } };")
  assert_false MV.event_running?
end

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
