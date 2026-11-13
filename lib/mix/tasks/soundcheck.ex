defmodule Mix.Tasks.Soundcheck do
  @shortdoc "Runs soundcheck's LiveView checks with full multi-location output"

  @moduledoc """
  Runs soundcheck outside Credo, for what Credo cannot show: every location
  a finding involves (template, handler, JavaScript), line-level output for
  findings located only in JavaScript (such as unused hooks), and SARIF with
  related locations.

      mix soundcheck
      mix soundcheck --format sarif --output soundcheck.sarif
      mix soundcheck --all --strict

  The task compiles the project first, because semantic checks read
  compiled modules. It exits with status 1 when it reports any finding that
  is not unverifiable.

  ## Options

    * `--format` - `text` (default), `json`, or `sarif`
    * `--output` - write to this file instead of standard output
    * `--all` - run every check, not only the default ones
    * `--only` - comma-separated check ids to run, such as `SC101,SC1002`
    * `--strict` - also report unverifiable findings
    * `--path` - a glob of Elixir sources, repeatable (default: `lib` and
      `web`, also under `apps/*` in an umbrella)
    * `--js-path` - a JavaScript directory, repeatable (default `assets/js`)
    * `--no-compile` - do not compile; load the existing build as it is
    * `--config-file` - the Credo config to read (default `.credo.exs`)
    * `--config-name` - the config within it (default `default`)
    * `--baseline` - a baseline file whose findings are not reported
      (default `.soundcheck_baseline.exs` when it exists)
    * `--no-baseline` - report every finding
    * `--write-baseline` - record the current findings in the baseline file
      and exit 0. Entries of checks that did not run, and with `--path`, of
      files outside its globs, stay in the file.

  Checks run with the parameters `.credo.exs` sets for them, as in
  `mix credo`, and the checks that file enables or disables are added to or
  removed from the defaults. `--only` and `--all` select checks regardless
  of the file. The `Soundcheck` plugin's `js_paths` param applies unless
  `--js-path` is given.
  """

  use Mix.Task

  alias Soundcheck.Baseline
  alias Soundcheck.Cache
  alias Soundcheck.Checks
  alias Soundcheck.Config
  alias Soundcheck.Diagnostic
  alias Soundcheck.Output.JSON
  alias Soundcheck.Output.SARIF
  alias Soundcheck.Output.Text
  alias Soundcheck.Runner

  @switches [
    format: :string,
    output: :string,
    all: :boolean,
    only: :string,
    strict: :boolean,
    path: :keep,
    js_path: :keep,
    compile: :boolean,
    baseline: :string,
    config_file: :string,
    config_name: :string,
    no_baseline: :boolean,
    write_baseline: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _args} = OptionParser.parse!(argv, strict: @switches)

    # `compile --no-compile` still puts the project's and its deps' ebin
    # directories on the code path; skipping `compile` entirely would leave
    # every project module unloadable.
    Mix.Task.run("compile", if(Keyword.get(opts, :compile, true), do: [], else: ["--no-compile"]))

    {:ok, _started} = Application.ensure_all_started(:soundcheck)
    Cache.clear()

    config =
      Config.read(
        Keyword.get(opts, :config_file, ".credo.exs"),
        Keyword.get(opts, :config_name, "default")
      )

    checks = checks(opts, config)

    # Runner and Graph own the path defaults; only paths the command line or
    # the plugin config name reach them.
    result =
      [
        checks: checks,
        check_params: Map.new(checks, &{&1, Config.params(config, &1)}),
        strict: Keyword.get(opts, :strict, false),
        baseline: baseline_path(opts)
      ]
      |> Keyword.merge(Keyword.take(config.plugin, [:js_paths]))
      |> put_globs(:paths, Keyword.get_values(opts, :path))
      |> put_globs(:js_paths, Keyword.get_values(opts, :js_path))
      |> Runner.run()

    for file <- result.unparsable,
        do: Mix.shell().error("soundcheck: skipped #{file}: it does not parse")

    if opts[:write_baseline] do
      write_baseline(result.diagnostics, opts, checks)
    else
      result.diagnostics
      |> render(Keyword.get(opts, :format, "text"), checks)
      |> write(opts[:output])

      if Enum.any?(result.diagnostics, &(not Diagnostic.unverifiable?(&1))),
        do: exit({:shutdown, 1})
    end
  end

  # A narrowed run (`--only`, `--path`) rewrites only the entries it could
  # reproduce. Templates and JavaScript files fall outside `--path` globs, so
  # a run with `--path` keeps their entries.
  defp write_baseline(diagnostics, opts, checks) do
    path = opts[:baseline] || Baseline.default_path()

    files =
      case Keyword.get_values(opts, :path) do
        [] -> :all
        globs -> Enum.flat_map(globs, &Path.wildcard/1)
      end

    kept = path |> Baseline.entries() |> Baseline.outside(Enum.map(checks, & &1.id()), files)
    File.write!(path, Baseline.render(diagnostics, kept))

    Mix.shell().info(
      "soundcheck: recorded #{length(diagnostics)} findings in #{path}" <>
        if(kept == [],
          do: "",
          else: ", kept #{length(kept)} from checks or files outside this run"
        )
    )
  end

  # Writing a baseline must see every finding, so it ignores the old one.
  defp baseline_path(opts) do
    if !(opts[:no_baseline] || opts[:write_baseline]),
      do: opts[:baseline] || Baseline.default_path()
  end

  defp checks(opts, config) do
    all = Checks.all()

    cond do
      only = opts[:only] ->
        ids = only |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
        selected = Enum.filter(all, &(&1.id() in ids))
        unknown = ids -- Enum.map(selected, & &1.id())
        if unknown != [], do: Mix.raise("Unknown check ids: #{Enum.join(unknown, ", ")}")
        selected

      opts[:all] ->
        all

      true ->
        Config.selected(config, Checks.defaults())
    end
  end

  defp put_globs(opts, _key, []), do: opts
  defp put_globs(opts, key, globs), do: Keyword.put(opts, key, globs)

  defp render(diagnostics, "text", _checks), do: Text.render(diagnostics)
  defp render(diagnostics, "json", _checks), do: JSON.render(diagnostics) <> "\n"
  defp render(diagnostics, "sarif", checks), do: SARIF.render(diagnostics, checks) <> "\n"

  defp render(_diagnostics, format, _checks),
    do: Mix.raise("Unknown --format #{inspect(format)}; use text, json, or sarif")

  defp write(output, nil), do: Mix.shell().info(output)
  defp write(output, path), do: File.write!(path, output)
end
