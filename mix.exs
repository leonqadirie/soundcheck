defmodule Soundcheck.MixProject do
  use Mix.Project

  @version "0.1.0"
  @description "A LiveView-aware Credo plugin that checks contracts between callbacks, HEEx templates, and JS hooks"

  def project do
    [
      app: :soundcheck,
      version: @version,
      description: @description,
      # soundcheck runs inside the host project's VM, so this floor stays as
      # low as the code allows: 1.17 added the `Macro.Env` alias functions
      # that `Soundcheck.Elixir.ModuleIndex` resolves aliases with.
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      elixirc_paths: elixirc_paths(Mix.env()),
      test_ignore_filters: [~r{^test/integration/fixtures/}],
      deps: deps(),
      dialyzer: dialyzer(),
      package: package(),
      docs: docs()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp aliases do
    [
      lint: [
        "compile",
        "format --check-formatted",
        "credo",
        "lint.no_emdash",
        "lint.readme_checks",
        "lint.reach",
        "xref graph --format cycles --fail-above 0",
        "dialyzer",
        "docs --warnings-as-errors"
      ]
    ]
  end

  defp elixirc_paths(:dev), do: ["lib", "dev"]
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # The lint tools are `:dev` only: several need a newer Elixir than
  # soundcheck's floor, and the test suite has to compile on the floor.
  # Quokka stays in `:test` because the installer tests format code with
  # the plugins `.formatter.exs` names.
  defp deps do
    [
      {:boxart, "~> 0.3", only: :dev, runtime: false},
      {:credo, "~> 1.7", runtime: false},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false},
      {:ex_dna, "~> 1.5", only: :dev, runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:ex_slop, "~> 0.4", only: :dev, runtime: false},
      {:igniter, "~> 0.8", optional: true, runtime: false},
      {:jason, "~> 1.4"},
      # Differential tests compare soundcheck's HEEx parser against LiveView's.
      {:phoenix_live_view, "~> 1.2", only: :test},
      {:quokka, "~> 2.13", only: [:dev, :test], runtime: false},
      {:reach, "~> 2.8", only: :dev, runtime: false},
      {:simple_sat, "~> 0.1", only: :dev, runtime: false},
      {:stream_data, "~> 1.3", only: [:dev, :test], runtime: false}
    ]
  end

  # PLTs live in priv/plts so CI can cache them. Mix and EEx are added because
  # the Mix tasks and the HEEx front end call them; Credo, Igniter, and
  # Sourceror are runtime: false dependencies, and Reach backs the dev-only
  # lint task, so none of them is in the app's own PLT.
  defp dialyzer do
    [
      plt_local_path: "priv/plts",
      plt_core_path: "priv/plts",
      plt_add_apps: [:mix, :eex, :credo, :igniter, :sourceror, :reach],
      flags: [:error_handling, :extra_return, :missing_return],
      ignore_warnings: ".dialyzer_ignore.exs",
      list_unused_filters: true
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      files: ~w(lib .formatter.exs mix.exs README* LICENSE* CHANGELOG* usage-rules.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: ["README.md"],
      filter_modules: &public_module?/2
    ]
  end

  # Internal modules hide themselves with `@moduledoc false`. The dev-only
  # `mix lint.*` tasks under `dev/` keep a moduledoc for `mix help`, so the
  # filter leaves them out of hexdocs.
  defp public_module?(module, _metadata),
    do: not match?(["Mix", "Tasks", "Lint" | _], Module.split(module))
end
