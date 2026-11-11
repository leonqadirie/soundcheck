defmodule Soundcheck.Check.Warning.PossiblyUnsetAssignTest do
  use Soundcheck.CheckCase

  import Soundcheck.HeexCase, only: [text_at: 2]

  alias Soundcheck.Check.Warning.PossiblyUnsetAssign

  @fixture "test/support/fixtures/unset.ex"
  @connected "test/support/fixtures/connected.ex"

  defp keys(diagnostics),
    do: Enum.map(diagnostics, &text_at(File.read!(&1.primary.file), &1.primary))

  test "fires on keys assigned only later or only on some branches" do
    diagnostics = analyze(PossiblyUnsetAssign, [{@fixture, File.read!(@fixture)}])

    assert keys(diagnostics) == ["@stats", "@debug"]
    assert Enum.all?(diagnostics, &(&1.resolution == :resolved))
  end

  test "near misses: both branches, handle_params, assume_set, and conditional reads" do
    found = keys(analyze(PossiblyUnsetAssign, [{@fixture, File.read!(@fixture)}]))

    for key <- ~w(@title @mode @page @current_user @hidden_detail @full_only) do
      refute key in found, "#{key} should not be reported"
    end
  end

  test "ignores mount paths that navigate away and counts keys render/1 assigns" do
    file = "test/support/fixtures/navigating.ex"
    diagnostics = analyze(PossiblyUnsetAssign, [{file, File.read!(file)}])

    assert keys(diagnostics) == ["@missing"]
  end

  test "reads the template a delegated render/1 renders" do
    file = "test/support/fixtures/delegated.ex"
    assert keys(analyze(PossiblyUnsetAssign, [{file, File.read!(file)}])) == ["@never_set"]
  end

  test "leaves connected-only keys to AssignSetOnlyWhenConnected" do
    assert [] = analyze(PossiblyUnsetAssign, [{@connected, File.read!(@connected)}])
  end
end
