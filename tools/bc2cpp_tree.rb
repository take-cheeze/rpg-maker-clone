# frozen_string_literal: true

# Where this repository finds bc2cpp (tools/bc2cpp, scripts/bc2cpp): this checkout unless BC2CPP_TREE_ROOT names
# another. bc2cpp compiles this repository's program, so BC2CPP_WORLD_ROOT is set before any of its code loads
# (tools/bc2cpp/world_root.rb).
BC2CPP_TREE = File.expand_path(ENV.fetch('BC2CPP_TREE_ROOT', File.expand_path('..', __dir__))) unless defined?(BC2CPP_TREE)
ENV['BC2CPP_WORLD_ROOT'] ||= File.expand_path('..', __dir__)
