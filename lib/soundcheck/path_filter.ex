defmodule Soundcheck.PathFilter do
  @moduledoc false
  # Shared `excluded_paths` matching for checks that exempt test directories by default.

  @doc """
  The shared `excluded_paths` default: test directories. Each check's
  `param_defaults` references this function so the defaults cannot drift
  apart.
  """
  @spec default_excluded_paths() :: [Regex.t() | String.t()]
  def default_excluded_paths, do: [~r"/test/", "test"]

  @doc """
  Returns `true` when `filename` matches any entry in `excluded_paths`.

  A `Regex` entry matches against the full filename. A binary entry
  matches as a path segment: the filename equals it, starts with
  `entry <> "/"`, or contains `"/" <> entry <> "/"`. So `"test"` excludes
  `test/foo.exs` and `/repo/test/foo.exs` but not `contest/foo.ex`. A
  trailing slash on a binary entry is ignored.
  """
  @spec excluded?(String.t(), [Regex.t() | String.t()]) :: boolean()
  def excluded?(filename, excluded_paths) do
    Enum.any?(excluded_paths, &matches?(filename, &1))
  end

  defp matches?(filename, %Regex{} = regex), do: Regex.match?(regex, filename)

  defp matches?(filename, path) when is_binary(path) do
    case String.trim_trailing(path, "/") do
      "" ->
        false

      segment ->
        filename == segment or
          String.starts_with?(filename, segment <> "/") or
          String.contains?(filename, "/" <> segment <> "/")
    end
  end
end
