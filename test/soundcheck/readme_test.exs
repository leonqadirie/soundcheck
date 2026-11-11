defmodule Soundcheck.ReadmeTest do
  use ExUnit.Case, async: true

  alias Soundcheck.Checks

  @readme Path.expand("../../README.md", __DIR__)
  @check_dir Path.expand("../../lib/soundcheck/check", __DIR__)

  test "the registry contains every check on disk exactly once" do
    discovered =
      @check_dir
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> Enum.map(fn path ->
        [category, filename] = path |> Path.relative_to(@check_dir) |> Path.split()

        "Soundcheck.Check.#{Macro.camelize(category)}.#{filename |> Path.rootname() |> Macro.camelize()}"
      end)

    assert_entries(discovered, Enum.map(Checks.all(), &inspect/1), "check registry")
  end

  test "the checks table matches metadata, defaults, and compiled-project requirements" do
    actual =
      @readme
      |> File.read!()
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "| SC"))

    expected =
      Checks.all()
      |> Enum.sort_by(fn check ->
        check.id() |> String.trim_leading("SC") |> String.to_integer()
      end)
      |> Enum.map(fn check ->
        cells = [
          check.id(),
          "`#{inspect(check)}`",
          check.category(),
          if(check.default?(), do: "on", else: "off"),
          check.tier(),
          check.confidence(),
          check.summary()
        ]

        "| " <> Enum.map_join(cells, " | ", &to_string/1) <> " |"
      end)

    assert actual == expected,
           "README check table is outdated; run mix lint.readme_checks --write"
  end

  test "the enable-all example contains every opt-in check exactly once in alphabetical order" do
    readme = File.read!(@readme)

    assert [_, block] =
             Regex.run(~r/To enable every opt-in check.*?```elixir\s*(.*?)```/s, readme),
           "README is missing the enable-all Elixir example"

    # Parse the example so malformed entries cannot silently escape the guard.
    assert {:ok, [checks: {:%{}, _, [extra: entries]}]} =
             Code.string_to_quoted("[" <> block <> "]")

    actual =
      Enum.map(entries, fn
        {{:__aliases__, _, parts}, []} -> Enum.join(parts, ".")
        entry -> flunk("Unexpected enable-all entry: #{Macro.to_string(entry)}")
      end)

    expected = Checks.all() |> Enum.reject(& &1.default?()) |> Enum.map(&inspect/1)
    assert_entries(expected, actual, "README enable-all example")
    assert actual == Enum.sort(actual), "README enable-all checks must be alphabetical"
  end

  test "shared parameter documentation matches the parameters every check accepts" do
    documented =
      @readme
      |> File.read!()
      |> section("Shared check parameters")
      |> parameter_rows()
      |> Enum.map(fn [parameter | _] -> parameter |> backticked() |> hd() end)

    expected =
      Checks.all()
      |> Enum.map(fn check -> check.param_defaults() |> Keyword.keys() |> MapSet.new() end)
      |> Enum.reduce(&MapSet.intersection/2)
      |> Enum.map(&Atom.to_string/1)

    assert_entries(expected, documented, "README shared parameters")
  end

  test "check-specific parameter documentation covers every parameter without unknown entries" do
    readme = File.read!(@readme)

    shared =
      readme
      |> section("Shared check parameters")
      |> parameter_rows()
      |> Enum.map(fn [parameter | _] -> parameter |> backticked() |> hd() end)

    actual =
      for [names, parameters | _] <-
            readme |> section("Check-specific parameters") |> parameter_rows(),
          name <- backticked(names),
          parameter <- backticked(parameters) do
        {name, parameter}
      end

    expected =
      for check <- Checks.all(),
          {parameter, _default} <- check.param_defaults(),
          parameter = Atom.to_string(parameter),
          parameter not in shared do
        {check |> Module.split() |> List.last(), parameter}
      end

    assert_entries(expected, actual, "README check-specific parameters")
  end

  defp section(readme, heading) do
    assert [_, rest] = String.split(readme, "### #{heading}\n", parts: 2),
           "README is missing the #{heading} section"

    rest |> String.split(~r/\n\#{2,3} /, parts: 2) |> hd()
  end

  # Split only at unescaped pipes: regex defaults contain escaped pipes.
  defp parameter_rows(section) do
    for line <- String.split(section, "\n"), String.starts_with?(line, "| `") do
      line
      |> String.trim("|")
      |> String.split(~r/(?<!\\)\|/)
      |> Enum.map(&String.trim/1)
    end
  end

  defp backticked(cell) do
    Regex.scan(~r/`(\w+)`/, cell, capture: :all_but_first)
    |> List.flatten()
  end

  defp assert_entries(expected, actual, label) do
    missing = expected -- actual
    unexpected = actual -- expected

    assert missing == [] and unexpected == [], """
    #{label} differs from the checks:
    Missing: #{inspect(missing)}
    Unexpected or duplicated: #{inspect(unexpected)}
    """
  end
end
