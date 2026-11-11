[
  layers: [
    plugin: "Soundcheck",
    registry: "Soundcheck.Checks",
    config: "Soundcheck.Config",
    application: "Soundcheck.Application",
    cache: ["Soundcheck.Cache", "Soundcheck.Once"],
    orchestration: ["Soundcheck.Credo.*", "Soundcheck.Check", "Soundcheck.Rule"],
    graph: ["Soundcheck.Graph", "Soundcheck.Graph.Input"],
    linker: ["Soundcheck.Graph.Link", "Soundcheck.Graph.Current"],
    runner: ["Soundcheck.Runner", "Soundcheck.Runner.*"],
    output: "Soundcheck.Output.*",
    checks: "Soundcheck.Check.*",
    filters: [
      "Soundcheck.PathFilter",
      "Soundcheck.NameFilter",
      "Soundcheck.Suppression",
      "Soundcheck.Suppression.*",
      "Soundcheck.Baseline"
    ],
    model: ["Soundcheck.Span", "Soundcheck.LineIndex", "Soundcheck.Diagnostic"],
    heex: "Soundcheck.Heex.*",
    elixir_front: "Soundcheck.Elixir.*",
    beam: "Soundcheck.Beam.*",
    js: "Soundcheck.JS.*",
    analysis: "Soundcheck.Analysis.*",
    mix_tasks: "Mix.Tasks.*"
  ],
  calls: [
    forbidden: [
      # The Beam layer is the only gateway to compiled modules: nothing else
      # loads modules, reads BEAM chunks, or probes generated functions, so
      # every private-API read sits behind its shape validation.
      {"Soundcheck.*",
       [
         "Code.ensure_loaded*",
         "Code.ensure_compiled*",
         ":code.get_object_code",
         ":beam_lib.*"
       ], except: ["Soundcheck.Beam.*"]},
      # A linter must never run the code it analyzes. Only the reader of
      # the project's own `.credo.exs` evaluates, as Credo does.
      {"Soundcheck.*", ["Code.eval_*", "Code.compile_*", "Code.require_file"],
       except: ["Soundcheck.Config"]},
      # Analyzed sources are untrusted input: creating atoms from their
      # strings could exhaust the atom table. The graph names the function
      # of each embedded `.heex` file as `embed_templates` does, an atom the
      # project's compilation creates too, at most one per template file.
      {"Soundcheck.*",
       [
         "String.to_atom",
         "List.to_atom",
         ":erlang.binary_to_atom",
         ":erlang.list_to_atom"
       ], except: ["Soundcheck.Graph"]},
      {"Soundcheck.*", ["System.cmd", "System.shell", "Port.open", ":os.cmd"]},
      # Run state lives in the cache processes, not in ETS tables, the
      # process dictionary, or persistent terms owned elsewhere.
      {"Soundcheck.*",
       [":ets.*", ":persistent_term.*", "Process.put", "Process.get", "Process.delete"],
       except: ["Soundcheck.Cache", "Soundcheck.Once"]},
      # Checks report `Soundcheck.Diagnostic`s; only the plugin entry point
      # and the Credo adapter speak Credo's API.
      {"Soundcheck.*", ["Credo.*"],
       except: ["Soundcheck", "Soundcheck.Check", "Soundcheck.Credo.*"]}
    ]
  ],
  boundaries: [
    # Front-end internals: parsers and lexers stay behind their front end's
    # public modules, so checks and analyses read parsed facts only.
    internal: [
      "Soundcheck.Heex.Lexer",
      "Soundcheck.Heex.Expr",
      "Soundcheck.Heex.Parser",
      "Soundcheck.Heex.OffsetMap",
      "Soundcheck.JS.Lexer",
      "Soundcheck.Elixir.Names",
      "Soundcheck.Elixir.Sigils"
    ],
    internal_callers: [
      {"Soundcheck.Heex.Lexer", ["Soundcheck.Heex.Parser"]},
      {"Soundcheck.Heex.Expr", ["Soundcheck.Heex.Parser"]},
      # ~H sigils and .heex files are parsed while the graph is built
      # Reach attributes the functions after a nested `defmodule` (Facts,
      # Entry, Sigil) to the nested module, so the parents' nested modules
      # count too.
      {"Soundcheck.Heex.Parser",
       ["Soundcheck.Elixir.Sigils", "Soundcheck.Elixir.Sigils.*", "Soundcheck.Graph"]},
      {"Soundcheck.Heex.OffsetMap",
       [
         "Soundcheck.Heex.Parser",
         "Soundcheck.Heex.Expr",
         "Soundcheck.Elixir.Sigils",
         "Soundcheck.Elixir.Sigils.*"
       ]},
      {"Soundcheck.JS.Lexer", ["Soundcheck.JS.Extractor", "Soundcheck.JS.Extractor.*"]},
      {"Soundcheck.Elixir.Names",
       [
         "Soundcheck.Elixir.ModuleIndex",
         "Soundcheck.Elixir.ModuleIndex.*",
         "Soundcheck.Elixir.Sigils",
         "Soundcheck.Elixir.Sigils.*"
       ]},
      {"Soundcheck.Elixir.Sigils",
       ["Soundcheck.Elixir.ModuleIndex", "Soundcheck.Elixir.ModuleIndex.*"]}
    ]
  ],
  deps: [
    # Allowlist mode: Reach reports every cross-layer edge not listed here,
    # including edges into layers added later. Same-layer calls stay allowed.
    # Only call edges count: module atoms in lists (supervisor children, the
    # check registry, Credo task registrations) and `use` are not edges, so
    # those layers list no dependency on what they name.
    mode: :allowlist,
    allowed: [
      # the Credo plugin entry point starts and resets the cache and reads
      # the default config from the registry
      plugin: [:cache, :registry],
      # the check list only names check modules
      registry: [],
      # the .credo.exs reader is a leaf
      config: [],
      # the standalone runner builds the graph and runs checks outside Credo
      runner: [:graph, :linker, :model, :registry, :filters, :orchestration],
      # renderers format diagnostics; they call check callbacks dynamically
      output: [:model],
      # the graph is assembled from the front ends, once per run
      graph: [:cache, :elixir_front, :heex, :js],
      # the linker adds the links between files that analyses compute, and
      # holds the run's graph in the cache
      linker: [:graph, :analysis, :cache],
      # checks query the graph and front-end facts through the Credo adapter
      checks: [:graph, :heex, :model, :filters, :analysis, :beam, :elixir_front],
      # analyses read compiled modules and source facts to answer rule
      # queries, and memoize per-module answers that walk an expanded AST
      analysis: [:cache, :beam, :graph, :elixir_front, :heex, :js, :model],
      # application only names the cache processes as supervisor children
      application: [],
      # cache is foundational; it reaches nothing in our code
      cache: [],
      # pipeline tasks build the graph and reset the cache; the Credo adapter
      # links each check's needs, projects diagnostics onto issues, and
      # loads the baseline once per run
      orchestration: [:cache, :graph, :linker, :filters, :model],
      # filters match paths, names, and suppression comments against findings
      filters: [:model],
      model: [],
      # the HEEx front end builds nodes from spans
      heex: [:model],
      # the Elixir front end finds ~H sigils, hands them to the HEEx parser,
      # and records module spans
      elixir_front: [:heex, :model],
      # the Beam layer memoizes its probes per run
      beam: [:cache],
      # the JS front end builds spans from byte offsets
      js: [:model],
      # `mix soundcheck` drives the runner and renders its findings
      mix_tasks: [:cache, :runner, :output, :model, :registry, :filters, :config]
    ]
  ],
  effects: [
    # Each layer lists exactly the effect classes it uses, so a new effect
    # anywhere needs a deliberate policy change. Only the cache processes
    # write ETS and send and receive messages; the cache waits for the
    # process that prints its missing-plugin hint. Files are read by the graph builder, the
    # runner, suppression and baseline filters, the config reader, and the
    # text renderer (for source excerpts); `mix soundcheck` writes reports.
    # :read also covers the Beam layer's module probes.
    by_layer: [
      plugin: [:pure, :unknown],
      application: [:pure, :io],
      cache: [:pure, :unknown, :exception, :read, :write, :io, :send, :receive],
      # `use Soundcheck.Check` raises at compile time on missing rule options
      orchestration: [:pure, :unknown, :exception],
      # a link accessor raises when the check did not declare the link
      graph: [:pure, :unknown, :read, :exception],
      linker: [:pure, :unknown, :read],
      # the registry asks each check for `default?/0`, a dynamic call
      registry: [:pure, :unknown],
      config: [:pure, :unknown, :read],
      runner: [:pure, :unknown, :read],
      output: [:pure, :unknown, :read],
      checks: [:pure, :unknown, :exception],
      analysis: [:pure, :unknown, :exception],
      filters: [:pure, :unknown, :exception, :read],
      # Diagnostic.new/4 raises on an unverifiable reason outside its type
      model: [:pure, :unknown, :exception],
      heex: [:pure, :unknown, :exception],
      elixir_front: [:pure, :unknown],
      beam: [:pure, :unknown, :read],
      js: [:pure, :unknown],
      mix_tasks: [:pure, :unknown, :exception, :read, :write, :io]
    ]
  ],
  checks: [
    # Fixed source set so the verdict does not depend on MIX_ENV.
    source_paths: ["lib", "dev"],
    layer_coverage: [require_all_modules: true, forbid_multiple_matches: true]
  ],
  smells: [strict: true]
]
