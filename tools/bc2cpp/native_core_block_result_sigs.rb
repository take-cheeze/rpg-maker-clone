# frozen_string_literal: true

require_relative 'native_core_result_sigs'
require_relative 'native_sigs'

# NativeCoreBlockResultSigs: the result class of core iterators called with a block (SENDB sites), read from the
# core_block_results table of sig/bc2cpp/declarations.rbs. A bare call (SEND) is not covered: its result is another
# class (an Enumerator), so the table is consulted only for a block call.
module NativeCoreBlockResultSigs
  PATH = NativeSigs.table('core_block_results')

  module_function

  # { 'Array' => { 'map' => 'Array', ... }, ... }, frozen, read once per path. Only Array results: the block overload.
  def kinds(path = PATH)
    @kinds ||= {}
    @kinds[path] ||= NativeCoreResultSigs.load_kinds(path, classes: %w[Array], form: :block)
  end

  # { 'Array' => { 'map' => 'Enumerator', ... }, ... }: the blockless overload (a bare SEND), Enumerator results only.
  def blockless_kinds(path = PATH)
    @blockless_kinds ||= {}
    @blockless_kinds[path] ||= NativeCoreResultSigs.load_kinds(path, classes: %w[Enumerator], form: :blockless)
  end
end
