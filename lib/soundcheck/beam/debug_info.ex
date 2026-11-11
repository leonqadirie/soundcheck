defmodule Soundcheck.Beam.DebugInfo do
  @moduledoc false
  # Reads the macro-expanded definitions of a compiled module from its
  # `debug_info` chunk.
  #
  # The `:debug_info_v1` chunk format is documented by Erlang's `beam_lib`;
  # the `:elixir_v1` backend payload is what Elixir tooling reads, but Elixir
  # does not document it as public API. Clause metadata carries `line` only,
  # without columns.
  #
  # Results are computed once per module per run through `Soundcheck.Once`.
  # Each `definitions/1` call still copies the whole expanded AST out of ETS,
  # so callers that derive facts from it memoize the derived result through
  # `Soundcheck.Once` too.
  #
  # Error modes:
  #
  #   * `{:error, :not_loadable}` - the module cannot be compiled or found,
  #     typically because the project is not compiled.
  #   * `{:error, :no_debug_info}` - the module was compiled without debug
  #     info (`elixirc_options: [debug_info: false]` or
  #     `@compile {:debug_info, false}`), or the chunk is unreadable.

  alias Soundcheck.Once

  @type clause ::
          {meta :: keyword(), args :: [Macro.t()], guards :: [Macro.t()], body :: Macro.t()}
  @type definition ::
          {{name :: atom(), arity()}, :def | :defp | :defmacro | :defmacrop, keyword(),
           [clause()]}
  @type info :: %{file: Path.t(), definitions: [definition()]}
  @type error :: :not_loadable | :no_debug_info

  @doc "Returns the module's source file and expanded definitions."
  @spec definitions(module()) :: {:ok, info()} | {:error, error()}
  def definitions(module) when is_atom(module),
    do: Once.run({__MODULE__, module}, fn -> read(module) end)

  @doc """
  Returns the clauses of `name/arity`, or `{:ok, []}` when the module
  defines no such function.
  """
  @spec clauses(module(), atom(), arity()) :: {:ok, [clause()]} | {:error, error()}
  def clauses(module, name, arity) do
    with {:ok, %{definitions: definitions}} <- definitions(module) do
      {:ok,
       Enum.find_value(definitions, [], fn
         {{^name, ^arity}, _kind, _meta, clauses} -> clauses
         _definition -> nil
       end)}
    end
  end

  defp read(module) do
    with {:module, ^module} <- Code.ensure_loaded(module),
         {^module, binary, _path} <- :code.get_object_code(module) do
      decode(module, binary)
    else
      _ -> {:error, :not_loadable}
    end
  end

  defp decode(module, binary) do
    with {:ok, {^module, [debug_info: {:debug_info_v1, backend, data}]}} <-
           :beam_lib.chunks(binary, [:debug_info]),
         {:ok, %{definitions: definitions, file: file}} <-
           backend.debug_info(:elixir_v1, module, data, []) do
      {:ok, %{file: file, definitions: definitions}}
    else
      _ -> {:error, :no_debug_info}
    end
  end
end
