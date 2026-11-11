defmodule Soundcheck.Elixir.Sigils do
  @moduledoc false
  # Finds `~H` sigils in an Elixir source AST and parses each into a
  # `Soundcheck.Heex.Template` with file positions.
  #
  # The AST must come from `Code.string_to_quoted/2` with `columns: true` and
  # `token_metadata: true`, as Credo parses source files. Each template's
  # owner is the innermost enclosing `defmodule` and `def`/`defp`, when the
  # module name is a literal alias.

  alias Soundcheck.Elixir.Names
  alias Soundcheck.Heex.OffsetMap
  alias Soundcheck.Heex.Parser
  alias Soundcheck.Heex.Template

  defmodule Sigil do
    @moduledoc false
    # One `~H` sigil: the sigil's and its body's AST metadata, the body text,
    # and the enclosing `{module, function}`, or `nil` when unknown.
    @enforce_keys [:meta, :body_meta, :body, :owner]
    defstruct [:meta, :body_meta, :body, :owner]

    @type t :: %__MODULE__{
            meta: keyword(),
            body_meta: keyword(),
            body: String.t(),
            owner: {module(), atom() | nil} | nil
          }
  end

  @type sigil :: Sigil.t()

  @doc "Parses every `~H` sigil in `ast` into a template."
  @spec templates(Macro.t(), String.t(), Path.t()) :: [Template.t()]
  def templates(ast, source, file) do
    for sigil <- find(ast) do
      Parser.parse(sigil.body,
        file: file,
        origin: :sigil,
        owner: sigil.owner,
        offset_map: OffsetMap.for_sigil(sigil.meta, sigil.body_meta, source)
      )
    end
  end

  @doc """
  Returns every `~H` sigil in `ast`, in source order, with its metadata,
  body, and owner.
  """
  @spec find(Macro.t()) :: [sigil()]
  def find(ast) do
    ast
    |> walk(%{module: nil, fun: nil}, [])
    |> Enum.reverse()
  end

  defp walk({:sigil_H, meta, [{:<<>>, body_meta, [body]}, _modifiers]}, ctx, acc)
       when is_binary(body),
       do: [%Sigil{meta: meta, body_meta: body_meta, body: body, owner: owner(ctx)} | acc]

  defp walk({:defmodule, _meta, [name, body]}, ctx, acc),
    do: walk(body, %{ctx | module: Names.module_name(name, ctx.module), fun: nil}, acc)

  defp walk({kind, _meta, [head | body]}, ctx, acc) when kind in [:def, :defp] do
    walk(body, %{ctx | fun: fun_name(head)}, acc)
  end

  defp walk({form, _meta, args}, ctx, acc) when is_list(args) do
    acc = walk(form, ctx, acc)
    walk(args, ctx, acc)
  end

  defp walk({left, right}, ctx, acc), do: walk(right, ctx, walk(left, ctx, acc))

  defp walk(list, ctx, acc) when is_list(list), do: Enum.reduce(list, acc, &walk(&1, ctx, &2))

  defp walk(_leaf, _ctx, acc), do: acc

  defp owner(%{module: nil}), do: nil
  defp owner(%{module: module, fun: fun}), do: {module, fun}

  defp fun_name({:when, _meta, [head | _guards]}), do: fun_name(head)
  defp fun_name({name, _meta, _args}) when is_atom(name), do: name
  defp fun_name(_head), do: nil
end
