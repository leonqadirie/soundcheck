defmodule Mix.Tasks.Bench do
  @shortdoc "Benchmarks soundcheck against the generated corpus"
  @moduledoc """
  Runs the benchmark groups in `Bench.Scenarios` against the corpus that
  `gen.exs` wrote.

      mix bench [--only GROUP]... [--size SIZE]... [--save TAG] [--compare TAG]

    * `--only` - a group to run: `e2e`, `stages`, `checks`, or `credo`
      (repeatable; default: all)
    * `--size` - a corpus size: `small`, `medium`, or `large` (repeatable;
      default: all sizes, and `medium` for `checks`)
    * `--save` - stores the results under `tmp/bench/TAG/`
    * `--compare` - loads the results saved under `TAG` and prints them next
      to this run

  `--save` writes each group's results and metadata (the corpus fingerprint,
  the scheduler count, and the OTP and Elixir versions) next to each other,
  and removes the group's previous files first. `--compare` refuses to run
  when any requested group's saved results come from a different corpus or
  lack metadata, and warns when the machine setup differs.
  """

  use Mix.Task

  @switches [save: :string, compare: :string, only: :keep, size: :keep]

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: @switches)
    Mix.Task.run("app.start")

    fingerprint =
      Bench.Corpus.read_fingerprint() || Mix.raise("no corpus found; run `task bench:gen` first")

    if opts[:save] != nil and opts[:save] == opts[:compare],
      do: Mix.raise("--save and --compare need different tags")

    meta = meta(fingerprint)
    groups = groups(opts)

    # Every group is checked before any runs, so a stale group fails fast.
    if tag = opts[:compare], do: Enum.each(groups, &check_meta!(tag, &1, meta))

    for group <- groups do
      if tag = opts[:save], do: remove_saved(tag, group)
      Benchee.run(Bench.Scenarios.jobs(group), config(group, opts))
      if tag = opts[:save], do: save_meta!(tag, group, meta)
    end
  end

  defp groups(opts) do
    case Keyword.get_values(opts, :only) do
      [] ->
        Bench.Scenarios.groups()

      groups ->
        Enum.each(groups, &(&1 in Bench.Scenarios.groups() or Mix.raise("unknown group #{&1}")))
        Enum.uniq(groups)
    end
  end

  defp sizes(group, opts) do
    case {Keyword.get_values(opts, :size), group} do
      {[], "checks"} -> [:medium]
      {[], _group} -> Bench.Corpus.sizes()
      {sizes, _group} -> sizes |> Enum.uniq() |> Enum.map(&size!/1)
    end
  end

  defp size!(name) do
    Enum.find(Bench.Corpus.sizes(), &(Atom.to_string(&1) == name)) ||
      Mix.raise("unknown size #{name}")
  end

  defp config(group, opts) do
    [
      title: group,
      inputs: Bench.Scenarios.inputs(group, sizes(group, opts)),
      formatters: [{Benchee.Formatters.Console, extended_statistics: true}]
    ]
    |> Keyword.merge(timing(group))
    |> put_save(opts[:save], group)
    |> put_load(opts[:compare], group)
  end

  # The checks group runs one job per check, so it gets shorter windows to
  # keep a full run under ten minutes.
  defp timing("checks"), do: [warmup: 1, time: 2, memory_time: 0.5, reduction_time: 0.5]

  defp timing(group) when group in ["e2e", "credo"],
    do: [warmup: 2, time: 10, memory_time: 1, reduction_time: 1]

  defp timing(_group), do: [warmup: 2, time: 5, memory_time: 1, reduction_time: 1]

  defp put_save(config, nil, _group), do: config

  defp put_save(config, tag, group),
    do: Keyword.put(config, :save, path: results_file(tag, group), tag: tag)

  defp put_load(config, nil, _group), do: config

  defp put_load(config, tag, group) do
    file = results_file(tag, group)

    if File.exists?(file) do
      Keyword.put(config, :load, file)
    else
      Mix.shell().info("no saved #{group} results under #{tag}; running without comparison")
      config
    end
  end

  defp results_file(tag, group), do: Path.join(Bench.results_dir(tag), "#{group}.benchee")
  defp meta_file(tag, group), do: Path.join(Bench.results_dir(tag), "#{group}.meta.exs")

  # ── Run metadata ──

  defp meta(fingerprint) do
    %{
      fingerprint: fingerprint,
      schedulers: System.schedulers_online(),
      otp: System.otp_release(),
      elixir: System.version(),
      soundcheck: soundcheck_revision()
    }
  end

  # The revision of the soundcheck checkout under test, marked dirty only
  # when its library sources or dependency files changed; edits to the bench
  # harness do not count.
  defp soundcheck_revision do
    dir = Mix.Project.deps_paths() |> Map.fetch!(:soundcheck)

    with {:ok, revision} <- git(dir, ["rev-parse", "--short", "HEAD"]),
         {:ok, changes} <- git(dir, ["status", "--porcelain", "--", "lib", "mix.exs", "mix.lock"]) do
      if changes == "", do: revision, else: revision <> "-dirty"
    else
      :error -> "unknown"
    end
  end

  defp git(dir, args) do
    case System.cmd("git", ["-C", dir | args], stderr_to_stdout: false) do
      {output, 0} -> {:ok, String.trim(output)}
      _failure -> :error
    end
  rescue
    # System.cmd raises when git is not installed.
    ErlangError -> :error
  end

  # A failed or interrupted run then leaves no results that a later
  # --compare could mistake for current ones.
  defp remove_saved(tag, group) do
    File.rm(results_file(tag, group))
    File.rm(meta_file(tag, group))
  end

  defp save_meta!(tag, group, meta) do
    File.mkdir_p!(Bench.results_dir(tag))
    File.write!(meta_file(tag, group), inspect(meta, pretty: true) <> "\n")
  end

  defp check_meta!(tag, group, meta) do
    file = meta_file(tag, group)

    cond do
      not File.exists?(results_file(tag, group)) ->
        :ok

      not File.exists?(file) ->
        Mix.raise(
          "the #{group} results under #{tag} have no metadata; re-save them with --save #{tag}"
        )

      true ->
        {saved, _binding} = Code.eval_file(file)

        if saved.fingerprint != meta.fingerprint,
          do:
            Mix.raise(
              "the corpus changed since #{tag} saved #{group}; re-save it with --save #{tag}"
            )

        Mix.shell().info(
          "#{group}: comparing soundcheck #{meta.soundcheck} against #{tag} (#{saved.soundcheck})"
        )

        for key <- [:schedulers, :otp, :elixir], saved[key] != meta[key] do
          Mix.shell().error(
            "warning: #{group} #{key} differs from #{tag}: #{saved[key]} then, #{meta[key]} now"
          )
        end
    end
  end
end
