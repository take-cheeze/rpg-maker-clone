- **bc2cpp census** now answers receiver origins for sends inside a `begin`/`rescue`/`ensure` range when the
  normal and the handler paths reach one definition (`BC2CPP_SITE_ORIGIN_EXCEPTIONS=1`, origin table only), and
  each refused origin names its cause. Generated code is unchanged. Covered by
  `scripts/bc2cpp_site_origin_exceptions_check.rb`; see `docs/bc2cpp-dynamic-site-census.md`.
