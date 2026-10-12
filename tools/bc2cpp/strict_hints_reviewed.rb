# frozen_string_literal: true

# STRICT_HINTS_REVIEWED (docs/adr/0411): every site BC2CPP_STRICT_HINTS=1 forces is a build error on a
# closed-world run unless its key is listed here. Key: "<compiled owner>#<compiled method> -> <name>
# (<FAMILY>)". Regenerate with `MRBC=... ruby scripts/bc2cpp/strict_hints_update.rb --write`; writing
# is not a review: the verify build (-DBC2CPP_NOMETHOD_VERIFY) over the real workloads is.
require 'set'

STRICT_HINTS_REVIEWED = Set[].freeze
