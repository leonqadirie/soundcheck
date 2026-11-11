defmodule Soundcheck.Baseline do
  @moduledoc false
  # Records today's findings so that only new ones are reported, for
  # adopting soundcheck on an existing codebase.
  #
  # The baseline file (`.soundcheck_baseline.exs` by default) holds a sorted
  # list of `{id, file, fingerprint}` tuples, readable Elixir terms that diff
  # cleanly in review. soundcheck parses the file without evaluating it. A fingerprint hashes the rule id, the file, the
  # message, and the finding's ordinal among identical findings in that file.
  # It contains no line numbers, so it survives edits elsewhere in the file;
  # changing the finding itself (renaming the event, moving it to another
  # file) makes it new.
  #
  # Rewriting a baseline replaces only the entries the run could have
  # reproduced: those of the checks that ran, in the files it analyzed.
  # `outside/3` picks the entries to carry over.

  alias Soundcheck.Diagnostic

  @default_path ".soundcheck_baseline.exs"

  @type entry :: {String.t(), Path.t(), String.t()}

  @doc "The default baseline path."
  @spec default_path() :: Path.t()
  def default_path, do: @default_path

  @doc "Sets the fingerprint of every diagnostic."
  @spec fingerprint([Diagnostic.t()]) :: [Diagnostic.t()]
  def fingerprint(diagnostics) do
    {fingerprinted, _seen} =
      diagnostics
      |> Enum.sort_by(&{&1.primary.file, &1.primary.start})
      |> Enum.map_reduce(%{}, fn diagnostic, seen ->
        key = {diagnostic.id, relative(diagnostic.primary.file), diagnostic.message}
        ordinal = Map.get(seen, key, 0)
        {%{diagnostic | fingerprint: hash(key, ordinal)}, Map.put(seen, key, ordinal + 1)}
      end)

    fingerprinted
  end

  @doc """
  Loads the baseline at `path` as a set of fingerprints. A missing file is
  an empty baseline; a malformed one raises.
  """
  @spec load(Path.t()) :: MapSet.t(String.t())
  def load(path \\ @default_path),
    do: path |> entries() |> MapSet.new(fn {_id, _file, fingerprint} -> fingerprint end)

  @doc """
  Reads the entries of the baseline at `path`. A missing file has none; a
  malformed one raises.

  The file is parsed, never evaluated: anything other than a literal list
  of `{id, file, fingerprint}` string tuples is malformed.
  """
  @spec entries(Path.t()) :: [entry()]
  def entries(path) do
    if File.regular?(path), do: parse!(File.read!(path), path), else: []
  end

  defp parse!(source, path) do
    with {:ok, ast} <- Code.string_to_quoted(source),
         true <- is_list(ast) and Enum.all?(ast, &entry?/1) do
      for {:{}, _meta, [id, file, fingerprint]} <- ast, do: {id, file, fingerprint}
    else
      _malformed ->
        raise ArgumentError,
              "malformed baseline #{path}: expected a list of {id, file, fingerprint} " <>
                "string tuples; regenerate it with `mix soundcheck --write-baseline`"
    end
  end

  defp entry?({:{}, _meta, [id, file, fingerprint]}),
    do: is_binary(id) and is_binary(file) and is_binary(fingerprint)

  defp entry?(_ast), do: false

  @doc """
  The `entries` a run could not have reproduced: those whose rule id is not
  in `ids`, or whose file is not in `files`. `files` is `:all` when the run
  analyzed the whole project.
  """
  @spec outside([entry()], [String.t()], [Path.t()] | :all) :: [entry()]
  def outside(entries, ids, files) do
    files = if files == :all, do: :all, else: MapSet.new(files, &relative/1)

    Enum.reject(entries, fn {id, file, _fingerprint} ->
      id in ids and (files == :all or MapSet.member?(files, file))
    end)
  end

  @doc "Drops diagnostics whose fingerprint is in `baseline`, fingerprinting them first."
  @spec reject([Diagnostic.t()], MapSet.t(String.t())) :: [Diagnostic.t()]
  def reject(diagnostics, baseline) do
    if MapSet.size(baseline) == 0,
      do: diagnostics,
      else: diagnostics |> fingerprint() |> Enum.reject(&MapSet.member?(baseline, &1.fingerprint))
  end

  @doc """
  Renders the baseline file contents that record `diagnostics`, plus the
  `kept` entries of an earlier baseline.
  """
  @spec render([Diagnostic.t()], [entry()]) :: String.t()
  def render(diagnostics, kept \\ []) do
    entries =
      diagnostics
      |> fingerprint()
      |> Enum.map(&{&1.id, relative(&1.primary.file), &1.fingerprint})
      |> Enum.concat(kept)
      |> Enum.uniq()
      |> Enum.sort()

    """
    # soundcheck baseline: findings recorded here are not reported.
    # Regenerate with `mix soundcheck --write-baseline`.
    #{inspect(entries, pretty: true, limit: :infinity)}
    """
  end

  defp hash({id, file, message}, ordinal) do
    :crypto.hash(:sha256, Enum.join([id, file, message, ordinal], <<0>>))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp relative(file), do: Path.relative_to_cwd(file)
end
