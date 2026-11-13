defmodule Soundcheck.Graph.Input do
  @moduledoc false
  # One parsed Elixir source file the graph is built from.

  @enforce_keys [:file, :source, :ast]
  defstruct [:file, :source, :ast]

  @type t :: %__MODULE__{file: Path.t(), source: String.t(), ast: Macro.t()}

  # The application sources of a Mix project or an umbrella: the
  # directories Credo's default config includes, without their tests.
  @default_globs ["{lib,web}/**/*.ex", "apps/*/{lib,web}/**/*.ex"]

  @doc """
  The globs of the Elixir sources a graph is built from when nothing
  names them: `mix soundcheck` without `--path`, and checks that run
  without the plugin.
  """
  @spec default_globs() :: [String.t()]
  def default_globs, do: @default_globs

  @doc """
  Reads and parses, in parallel, every file the `globs` match. Returns the
  inputs in path order and the paths of the files that do not parse.
  """
  @spec load([String.t()]) :: {[t()], unparsable :: [Path.t()]}
  def load(globs) do
    globs
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Task.async_stream(&{&1, parse(&1, File.read!(&1))}, ordered: true, timeout: :infinity)
    |> Enum.reduce({[], []}, fn
      {:ok, {_file, {:ok, input}}}, {inputs, unparsable} -> {[input | inputs], unparsable}
      {:ok, {file, :error}}, {inputs, unparsable} -> {inputs, [file | unparsable]}
    end)
    |> then(fn {inputs, unparsable} -> {Enum.reverse(inputs), Enum.reverse(unparsable)} end)
  end

  @doc """
  Parses `source` the way Credo does (`columns: true, token_metadata: true`),
  or returns `:error` when it does not parse.
  """
  @spec parse(Path.t(), String.t()) :: {:ok, t()} | :error
  def parse(file, source) do
    case Code.string_to_quoted(source, columns: true, token_metadata: true, emit_warnings: false) do
      {:ok, ast} -> {:ok, %__MODULE__{file: file, source: source, ast: ast}}
      {:error, _reason} -> :error
    end
  end
end
