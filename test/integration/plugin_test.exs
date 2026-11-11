defmodule Soundcheck.PluginIntegrationTest do
  @moduledoc """
  Boots Credo against `fixtures/plugin_smoke/`, whose `.credo.exs`
  registers `{Soundcheck, []}`, and checks the plugin's wiring end to end.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Credo.CLI.Output.Shell
  alias Soundcheck.Cache

  @fixture_dir Path.expand("fixtures/plugin_smoke", __DIR__)

  test "the plugin initializes, Credo runs, and the run ends with an empty cache" do
    Cache.put(:stale_from_previous_run, true)

    exec = run_credo()

    refute exec.halted
    assert Cache.get(:stale_from_previous_run) == nil
    assert Soundcheck.Credo.ClearCacheTask in halt_tasks(exec)
    assert Soundcheck.Credo.BuildGraphTask in suggest_analysis_tasks(exec)
    assert %{modules: 2, templates: 1} = Credo.Execution.get_assign(exec, "soundcheck.graph")
  end

  test "default checks report through Credo" do
    exec = run_credo()

    assert [issue] = issues_of(exec, Soundcheck.Check.Warning.UndeclaredComponentAttr)
    assert String.ends_with?(issue.filename, "plugin_smoke/lib/components.ex")
    assert {issue.line_no, issue.column} == {10, 9}
    assert issue.message =~ "`card/1` reads `@subtitle`"
  end

  test "per-check Credo params such as priority reach the issues" do
    assert [issue] = issues_of(run_credo(), Soundcheck.Check.Warning.UndeclaredComponentAttr)
    # Credo adds a small per-file adjustment; the check's base is :high (10).
    assert issue.priority >= Credo.Priority.to_integer(:higher)
  end

  test "findings located only in JavaScript report against the JavaScript file" do
    exec = run_credo()

    assert [issue] = issues_of(exec, Soundcheck.Check.Design.UnusedHook)
    assert issue.filename == "test/integration/fixtures/plugin_smoke/assets/js/app.js"
    assert {issue.line_no, issue.column} == {nil, nil}

    assert issue.message =~
             ~r"^test/integration/fixtures/plugin_smoke/assets/js/app.js:6:\d+: Hook `Unused`"
  end

  test "Credo's verbose, JSON, SARIF, and flycheck output render soundcheck issues" do
    for args <- [
          ["--verbose"],
          ["--format", "json"],
          ["--format", "sarif"],
          ["--format", "flycheck"]
        ] do
      # The JSON, SARIF, and flycheck formatters print to stdout directly.
      capture_io(fn ->
        assert [_ | _] = soundcheck_issues(run_credo(args)), "no issues with #{inspect(args)}"
      end)
    end
  end

  test "two runs in one VM report the same issues" do
    first = run_credo() |> soundcheck_issues() |> Enum.map(&{&1.filename, &1.line_no, &1.message})

    second =
      run_credo() |> soundcheck_issues() |> Enum.map(&{&1.filename, &1.line_no, &1.message})

    assert first == second
  end

  # Credo prints through a globally registered shell process, so CaptureIO
  # cannot intercept it; `suppress_output/1` silences it and the exec comes
  # back by message because the function returns the shell call's result.
  defp run_credo(args \\ ["--format", "oneline"]) do
    parent = self()

    Shell.suppress_output(fn ->
      exec =
        Credo.run(
          [
            "--config-file",
            Path.join(@fixture_dir, ".credo.exs"),
            "--working-dir",
            @fixture_dir,
            "--mute-exit-status"
          ] ++ args
        )

      send(parent, {:credo_exec, exec})
    end)

    assert_received {:credo_exec, exec}
    exec
  end

  defp issues_of(exec, check),
    do: exec |> soundcheck_issues() |> Enum.filter(&(&1.check == check))

  defp soundcheck_issues(exec) do
    exec
    |> Credo.Execution.get_issues()
    |> Enum.filter(&String.starts_with?(inspect(&1.check), "Soundcheck."))
  end

  # Credo keys command pipelines by name (`suggest_command.ex:37`).
  defp suggest_analysis_tasks(exec) do
    exec.pipeline_map
    |> Map.fetch!("suggest")
    |> Keyword.get(:run_analysis, [])
    |> Enum.map(fn
      {task, _opts} -> task
      task -> task
    end)
  end

  # Credo keys its main pipeline by the `Credo.Execution` module
  # (`execution.ex:74`); the accessor is private, so the test reads the map.
  defp halt_tasks(exec) do
    exec.pipeline_map
    |> Map.fetch!(Credo.Execution)
    |> Keyword.get(:halt_execution, [])
    |> Enum.map(fn
      {task, _opts} -> task
      task -> task
    end)
  end
end
