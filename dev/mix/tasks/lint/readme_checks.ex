defmodule Mix.Tasks.Lint.ReadmeChecks do
  @shortdoc "Checks the README's check table against the checks"

  @moduledoc """
  Renders the README's check table from `Soundcheck.Checks.all/0` and each
  check's metadata, and fails when the README differs. `--write` replaces
  the table in the README instead.
  """

  use Mix.Task

  @readme "README.md"
  @header [
    "| ID | Check | Category | Default | Tier | Confidence | What it catches |",
    "|---|---|---|---|---|---|---|"
  ]

  @impl true
  def run(args) do
    Mix.Task.run("compile")

    readme = File.read!(@readme)
    updated = replace_table(readme, table())

    cond do
      updated == readme ->
        Mix.shell().info("The README's check table matches the checks.")

      "--write" in args ->
        File.write!(@readme, updated)
        Mix.shell().info("Rewrote the README's check table.")

      true ->
        Mix.raise(
          "The README's check table differs from the checks' metadata. " <>
            "Run `mix lint.readme_checks --write` to regenerate it."
        )
    end
  end

  defp table do
    rows =
      Soundcheck.Checks.all()
      |> Enum.sort_by(&id_number/1)
      |> Enum.map(&row/1)

    @header ++ rows
  end

  defp id_number(check) do
    "SC" <> number = check.id()
    String.to_integer(number)
  end

  defp row(check) do
    cells =
      Enum.map(
        [
          check.id(),
          "`#{inspect(check)}`",
          check.category(),
          if(check.default?(), do: "on", else: "off"),
          check.tier(),
          check.confidence(),
          check.summary()
        ],
        &to_string/1
      )

    IO.iodata_to_binary(["| ", Enum.intersperse(cells, " | "), " |"])
  end

  # The table runs from its header line to the first line that is not a row.
  defp replace_table(readme, table) do
    lines = String.split(readme, "\n")
    [header | _] = @header
    start = Enum.find_index(lines, &(&1 == header)) || Mix.raise("No check table in #{@readme}.")
    {before, rest} = Enum.split(lines, start)
    after_table = Enum.drop_while(rest, &String.starts_with?(&1, "|"))

    Enum.join(before ++ table ++ after_table, "\n")
  end
end
