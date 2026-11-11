defmodule Mix.Tasks.SoundcheckTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Shell.Process, as: ProcessShell
  alias Mix.Tasks.Soundcheck, as: SoundcheckTask

  @fixture_args [
    "--no-compile",
    "--path",
    "test/support/fixtures/events.ex",
    "--js-path",
    "test/support/fixtures/assets/js"
  ]

  defp run_task(args) do
    Mix.shell(ProcessShell)

    status =
      try do
        SoundcheckTask.run(args)
        0
      catch
        :exit, {:shutdown, status} -> status
      end

    output = receive_output()
    {status, output}
  after
    Mix.shell(Mix.Shell.IO)
  end

  defp receive_output(acc \\ "") do
    receive do
      {:mix_shell, :info, [text]} -> receive_output(acc <> text)
    after
      0 -> acc
    end
  end

  test "reports findings, including JavaScript-only ones, and exits 1" do
    {status, output} = run_task(["--all", "--format", "json" | @fixture_args])
    entries = JSON.decode!(output)

    assert status == 1
    assert "SC101" in Enum.map(entries, & &1["id"])

    assert %{"location" => %{"file" => "test/support/fixtures/assets/js/hooks/extra.js"}} =
             Enum.find(entries, &(&1["id"] == "SC1002"))
  end

  test "--only selects checks by id" do
    {_status, output} = run_task(["--only", "SC1002", "--format", "json" | @fixture_args])
    assert output |> JSON.decode!() |> Enum.map(& &1["id"]) |> Enum.uniq() == ["SC1002"]
  end

  test "exits 0 without findings" do
    {status, output} = run_task(["--only", "SC104" | @fixture_args])
    assert status == 0
    assert output =~ "0 findings"
  end

  test "rejects unknown check ids and formats" do
    assert_raise Mix.Error, ~r/Unknown check ids: SC999/, fn ->
      run_task(["--only", "SC999" | @fixture_args])
    end

    assert_raise Mix.Error, ~r/Unknown --format/, fn ->
      run_task(["--format", "xml" | @fixture_args])
    end
  end

  @tag :tmp_dir
  test "a written baseline silences the recorded findings", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "baseline.exs")

    {0, output} = run_task(["--all", "--write-baseline", "--baseline", path | @fixture_args])
    assert output =~ "recorded"

    assert {0, output} = run_task(["--all", "--baseline", path | @fixture_args])
    assert output =~ "0 findings"

    assert {1, _output} = run_task(["--all", "--no-baseline" | @fixture_args])
  end

  @tag :tmp_dir
  test "a narrowed --write-baseline keeps entries of other checks and files", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "baseline.exs")
    {0, _output} = run_task(["--all", "--write-baseline", "--baseline", path | @fixture_args])

    {0, output} =
      run_task(["--only", "SC101", "--write-baseline", "--baseline", path | @fixture_args])

    assert output =~ "kept"

    other_file =
      ["--path", "test/support/fixtures/connected.ex"] ++
        (@fixture_args -- ["--path", "test/support/fixtures/events.ex"])

    {0, _output} = run_task(["--all", "--write-baseline", "--baseline", path | other_file])

    assert {0, output} = run_task(["--all", "--baseline", path | @fixture_args])
    assert output =~ "0 findings"
  end

  @tag :tmp_dir
  test "applies check selection and params from .credo.exs", %{tmp_dir: tmp_dir} do
    config = Path.join(tmp_dir, "credo.exs")

    File.write!(config, """
    %{configs: [%{name: "default", checks: [
      {Soundcheck.Check.Warning.UnhandledEvent, [ignore_events: [~r/missing/]]},
      {Soundcheck.Check.Warning.UnhandledHookEvent, false}
    ]}]}
    """)

    {_status, output} =
      run_task(["--format", "json", "--no-baseline", "--config-file", config | @fixture_args])

    entries = JSON.decode!(output)
    messages = for %{"id" => "SC101", "message" => message} <- entries, do: message

    assert Enum.any?(messages, &(&1 =~ "incr"))
    refute Enum.any?(messages, &(&1 =~ "missing"))
    refute Enum.any?(entries, &(&1["id"] == "SC103"))
  end

  @tag :tmp_dir
  test "writes to --output", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "soundcheck.sarif")
    _ = capture_io(fn -> run_task(["--format", "sarif", "--output", path | @fixture_args]) end)

    assert %{"version" => "2.1.0"} = path |> File.read!() |> JSON.decode!()
  end
end
