defmodule Soundcheck.NameFilter do
  @moduledoc false
  # Shared matching for check params that mix exact names and regexes.

  @doc """
  Returns `true` when `name` matches any entry in `entries`.

  A `Regex` entry matches the stringified name: atoms (including module
  aliases, which callers resolve before matching) and binaries such as
  event names. Any other entry matches by equality, so an atom entry
  matches only that atom and a binary entry only that binary.
  """
  @spec matches_any?(term(), [term()]) :: boolean()
  def matches_any?(name, entries), do: Enum.any?(entries, &matches?(name, &1))

  defp matches?(name, %Regex{} = regex) when is_binary(name), do: Regex.match?(regex, name)
  defp matches?(name, %Regex{} = regex) when is_atom(name), do: Regex.match?(regex, to_name(name))
  defp matches?(_name, %Regex{}), do: false
  defp matches?(name, entry), do: name == entry

  # Module aliases match as written in source (`MyAppWeb.UserLive`), plain
  # atoms without the leading colon (`tick`).
  defp to_name(atom) do
    case Atom.to_string(atom) do
      "Elixir." <> _ -> inspect(atom)
      string -> string
    end
  end
end
