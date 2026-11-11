# Used by "mix format"
[
  # Test fixtures use Phoenix DSL calls; keep them formatted as Phoenix
  # projects write them. Phoenix is a test-only dependency, so import_deps
  # cannot pull these in for the :dev formatter.
  locals_without_parens: [
    attr: 2,
    attr: 3,
    slot: 1,
    slot: 2,
    slot: 3,
    live: 2,
    live: 3,
    live: 4,
    live_session: 2,
    live_session: 3,
    on_mount: 1,
    embed_templates: 1,
    embed_templates: 2
  ],
  inputs: ["{mix,.formatter}.exs", "{config,dev,lib,test}/**/*.{ex,exs}"],
  plugins: [Quokka]
]
