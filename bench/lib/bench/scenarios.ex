defmodule Bench.Scenarios do
  @moduledoc """
  The benchmark groups: their jobs and their inputs per corpus size.

    * `e2e` - `Soundcheck.Runner.run/1` with every check, cold (cache cleared
      before each run) and warm (BEAM introspection memoized)
    * `stages` - each front-end stage over preloaded sources, without file
      reads in the timed function
    * `checks` - each check's `analyze/2` over a graph built once, with the
      cache cleared before each run so a check pays for the introspection it
      triggers
    * `credo` - a full in-process `mix credo` run with every soundcheck check
      enabled; without `--strict`, Credo skips the `:low`-priority ones. The
      run happens in a separate process, so Benchee's memory and
      reduction counts do not cover it

  Every job carries its own `before_each` hook. Benchee runs a global hook
  before every job's own hook, so a global cache clear would turn the warm
  job cold.
  """

  alias Credo.CLI.Output.Shell
  alias Soundcheck.Cache
  alias Soundcheck.Elixir.ModuleIndex
  alias Soundcheck.Elixir.Sigils
  alias Soundcheck.Graph
  alias Soundcheck.Graph.Input
  alias Soundcheck.Heex.Parser
  alias Soundcheck.JS.Extractor
  alias Soundcheck.Runner

  @groups ~w(e2e stages checks credo)

  @doc "The group names, in run order."
  @spec groups() :: [String.t()]
  def groups, do: @groups

  @doc "The jobs of `group`, as a Benchee job map."
  @spec jobs(String.t()) :: map()
  def jobs("e2e") do
    %{
      "runner cold" => {&run_all/1, before_each: &clear/1},
      "runner warm" => &run_all/1
    }
  end

  def jobs("stages") do
    %{
      "input parse" => fn data ->
        Enum.map(data.sources, fn {file, source} -> Input.parse(file, source) end)
      end,
      "module index" => fn data ->
        Enum.map(data.inputs, &ModuleIndex.modules(&1.ast, &1.source, &1.file))
      end,
      "graph build" => fn data -> Graph.build(data.inputs, js_paths: [data.js_dir]) end,
      "heex parse" => fn data -> Enum.map(data.heex, &Parser.parse/1) end,
      "js extract" => fn data ->
        Enum.map(data.js, fn {file, source} -> Extractor.extract(source, file: file) end)
      end
    }
  end

  def jobs("checks") do
    Map.new(all_checks(), fn check ->
      params = check.param_defaults()
      {check_name(check), {&check.analyze(&1, params), before_each: &clear/1}}
    end)
  end

  # The plugin's init/1 clears the cache at the start of every Credo run.
  def jobs("credo"), do: %{"credo suggest" => &run_credo/1}

  @doc "The Benchee inputs of `group` for `sizes`, smallest first."
  @spec inputs(String.t(), [atom()]) :: [{String.t(), term()}]
  def inputs(group, sizes), do: Enum.map(sizes, &{Atom.to_string(&1), input(group, &1)})

  defp input("e2e", size), do: size

  defp input("stages", size) do
    sources = for file <- Path.wildcard(Bench.elixir_glob(size)), do: {file, File.read!(file)}
    inputs = for {file, source} <- sources, {:ok, input} <- [Input.parse(file, source)], do: input
    heex_files = Path.wildcard(Path.join(Bench.size_dir(size), "lib/**/*.heex"))
    sigils = for input <- inputs, sigil <- Sigils.find(input.ast), do: sigil.body

    js =
      for file <- Path.wildcard(Path.join(Bench.js_dir(size), "**/*.js")),
          do: {file, File.read!(file)}

    %{
      sources: sources,
      inputs: inputs,
      heex: Enum.map(heex_files, &File.read!/1) ++ sigils,
      js: js,
      js_dir: Bench.js_dir(size)
    }
  end

  defp input("checks", size) do
    inputs =
      for file <- Path.wildcard(Bench.elixir_glob(size)),
          {:ok, input} <- [Input.parse(file, File.read!(file))],
          do: input

    Graph.build(inputs, js_paths: [Bench.js_dir(size)])
  end

  defp input("credo", size) do
    {:ok, _apps} = Application.ensure_all_started(:credo)
    config = Path.join(System.tmp_dir!(), "soundcheck-bench-credo.exs")
    File.write!(config, credo_config())
    {Bench.size_dir(size), config}
  end

  defp run_all(size) do
    Runner.run(
      paths: [Bench.elixir_glob(size)],
      js_paths: [Bench.js_dir(size)],
      checks: all_checks(),
      baseline: nil
    )
  end

  # Credo resolves `included` and soundcheck resolves `js_paths` against the
  # current directory, so the run changes into the corpus size's directory.
  # Benchee runs one job at a time, so the VM-wide cwd change is safe.
  #
  # Every Credo run starts linked servers that hold the parsed corpus and
  # never stop. The run happens in a process this function kills afterwards,
  # which takes the servers down with it; otherwise memory grows with every
  # iteration and slows the later ones.
  defp run_credo({dir, config}) do
    parent = self()
    ref = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        File.cd!(dir, fn ->
          Shell.suppress_output(fn ->
            Credo.run(["--config-file", config, "--mute-exit-status", "--format", "oneline"])
          end)
        end)

        send(parent, {ref, :done})
        Process.sleep(:infinity)
      end)

    receive do
      {^ref, :done} -> :ok
      {:DOWN, ^monitor, :process, ^pid, reason} -> exit(reason)
    end

    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    end
  end

  # The checks come from the soundcheck under test, so the config enables
  # exactly the checks that commit ships.
  defp credo_config do
    checks = Enum.map(all_checks(), &{&1, []})

    inspect(
      %{
        configs: [
          %{
            name: "default",
            files: %{included: ["lib/"]},
            plugins: [{Soundcheck, [js_paths: ["assets/js"]]}],
            checks: %{enabled: checks}
          }
        ]
      },
      limit: :infinity
    )
  end

  defp all_checks, do: Soundcheck.Checks.all()

  defp check_name(check), do: check |> inspect() |> String.replace_prefix("Soundcheck.Check.", "")

  defp clear(input) do
    Cache.clear()
    input
  end
end
