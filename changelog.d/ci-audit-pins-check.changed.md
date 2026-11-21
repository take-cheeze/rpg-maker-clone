- CI now runs `scripts/bc2cpp/audit_pins_check.rb` in the `ruby-checks`
  job. An edit to an audited native file now fails its own pull request
  instead of quietly switching off the closed bc2cpp build's audits.
