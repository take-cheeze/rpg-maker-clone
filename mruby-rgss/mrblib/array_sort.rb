# Array#sort / #sort! with a comparator that answers -2.
#
# mruby uses -2 as its "the block did not answer with a number" sentinel *and*
# assigns the block's own answer to the same variable (3rd/mruby/src/array.c,
# sort_cmp):
#
#     mrb_value c = mrb_yield_argv(mrb, blk, 2, args);
#     if (mrb_nil_p(c) || !mrb_fixnum_p(c)) { cmp = -2; }
#     else { cmp = mrb_fixnum(c); }
#     ...
#     if (cmp == -2) { mrb_raise(mrb, E_ARGUMENT_ERROR, "comparison failed"); }
#
# so a comparator that legitimately answers -2 raises `ArgumentError:
# comparison failed`. Ruby only ever specifies the *sign* of a comparator, and
# RGSS's own scripts are written to return a difference rather than -1/0/1:
#
#     @action_battlers.sort! {|a, b|
#       b.current_action.speed - a.current_action.speed }
#
# — `Scene_Battle#make_action_orders`, which every RPG Maker XP game runs at the
# start of every battle turn. Two battlers whose speeds differ by exactly two,
# in that order, end the game. That is why the boot check's battle pass failed
# on about half of all random seeds and passed on the rest
# (docs/rpgxp-rgss-api-gap.md, gap 0k).
#
# Normalising the answer to -1/0/1 makes the sentinel unreachable while keeping
# mruby's own C sort underneath, so the cost is one extra block call per
# comparison rather than a sort written in Ruby. A comparator that answers
# something *not* comparable still raises mruby's own "comparison failed",
# because nil is what that path hands back.
#
# Engine-wide rather than RGSS-only: this is mruby's arithmetic, and the
# RPG2000 runtime sorts with difference blocks too.
class Array
  alias_method :_rgss_native_sort, :sort
  alias_method :_rgss_native_sort!, :sort!

  def sort(&block)
    return _rgss_native_sort if block.nil?
    _rgss_native_sort { |a, b| RGSS._comparison_sign(block.call(a, b)) }
  end

  def sort!(&block)
    return _rgss_native_sort! if block.nil?
    _rgss_native_sort! { |a, b| RGSS._comparison_sign(block.call(a, b)) }
  end
end

module RGSS
  # The sign of a comparator's answer, or nil when it has none — nil is what
  # mruby's sort treats as a failed comparison, so an unusable answer still
  # raises exactly what it raised before.
  def self._comparison_sign(value)
    return -1 if value < 0
    return 1 if value > 0
    0
  rescue StandardError
    nil
  end
end
