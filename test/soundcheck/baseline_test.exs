defmodule Soundcheck.BaselineTest do
  use ExUnit.Case, async: true

  alias Soundcheck.Baseline
  alias Soundcheck.Diagnostic
  alias Soundcheck.Span

  defp diagnostic(line, message \\ "`phx-click=\"x\"` has no handler.") do
    span = Span.new("lib/demo.ex", {line, 3}, {line, 4})

    %Diagnostic{
      rule: Soundcheck.Check.Warning.UnhandledEvent,
      id: "SC101",
      message: message,
      primary: span,
      anchor: span
    }
  end

  test "fingerprints ignore line numbers" do
    [before] = Baseline.fingerprint([diagnostic(10)])
    [shifted] = Baseline.fingerprint([diagnostic(42)])

    assert before.fingerprint == shifted.fingerprint
  end

  test "identical findings in one file get distinct fingerprints by order" do
    fingerprints =
      [diagnostic(10), diagnostic(20)] |> Baseline.fingerprint() |> Enum.map(& &1.fingerprint)

    assert [_first, _second] = Enum.uniq(fingerprints)
  end

  test "a different message is a new finding" do
    [a] = Baseline.fingerprint([diagnostic(10)])
    [b] = Baseline.fingerprint([diagnostic(10, "`phx-click=\"y\"` has no handler.")])
    refute a.fingerprint == b.fingerprint
  end

  @tag :tmp_dir
  test "render/1 and load/1 round-trip, and reject/2 drops recorded findings", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "baseline.exs")
    File.write!(path, Baseline.render([diagnostic(10)]))

    baseline = Baseline.load(path)
    assert MapSet.size(baseline) == 1

    new = diagnostic(30, "`phx-click=\"new\"` has no handler.")
    assert [%{message: message}] = Baseline.reject([diagnostic(12), new], baseline)
    assert message =~ "new"
  end

  @tag :tmp_dir
  test "entries/1 parses the file without evaluating it", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "baseline.exs")
    File.write!(path, ~s|send(self(), :evaluated)\n[{"SC101", "lib/demo.ex", "abc"}]\n|)

    assert_raise ArgumentError, ~r/malformed baseline/, fn -> Baseline.entries(path) end
    refute_received :evaluated
  end

  @tag :tmp_dir
  test "entries/1 rejects entries that are not string triples", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "baseline.exs")

    for content <- [~s|[{"SC101", "lib/demo.ex"}]|, ~s|[{"SC101", :file, "abc"}]|, "", ":ok"] do
      File.write!(path, content)
      assert_raise ArgumentError, ~r/malformed baseline/, fn -> Baseline.entries(path) end
    end
  end

  test "a missing baseline file is empty" do
    assert Baseline.load("does/not/exist.exs") == MapSet.new()
  end
end
