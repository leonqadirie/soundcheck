defmodule Bench.MixProject do
  use Mix.Project

  # The bench project plays the host app: it compiles the generated corpus and
  # loads soundcheck as a dependency, so soundcheck analyzes and introspects
  # the corpus inside the corpus's VM, as it does in production.
  def project do
    [
      app: :bench,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: ["lib", "corpus"],
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [:logger]]

  # SOUNDCHECK_PATH points the benchmarks at another checkout, for example a
  # worktree of the base commit.
  defp deps do
    [
      {:soundcheck, path: System.get_env("SOUNDCHECK_PATH", "..")},
      {:benchee, "~> 1.3"},
      {:jason, "~> 1.4"},
      # The same version the root project tests against, pinned so A/B runs
      # analyze identical LiveView metadata.
      {:phoenix_live_view, "1.2.12"}
    ]
  end
end
