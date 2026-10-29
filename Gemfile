# frozen_string_literal: true

# Host-side bc2cpp checks (scripts/bc2cpp/*_check.rb, scripts/bc2cpp/base_rbs*.rb). They need the Prism and RBS
# versions the compiler is written against: Prism 1.x (`IfNode#subsequent`) and RBS 4.x (`TypeParam#upper_bound_type`).
# The system Ruby ships Prism 0.19 and RBS 3.4, which fail those checks. Use: bundle exec ruby scripts/bc2cpp/<check>.rb
# The TypeProf environment is separate (tools/typing/Gemfile, RBS 3.4).
source 'https://rubygems.org'

gem 'prism', '1.9.0'
gem 'rbs', '4.0.0'
gem 'rake', '13.4.2'
