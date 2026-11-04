# frozen_string_literal: true

# Regexp is OnigRegexp unless another gem has defined it.
Regexp = OnigRegexp unless defined?(Regexp)
