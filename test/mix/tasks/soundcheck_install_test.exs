defmodule Mix.Tasks.Soundcheck.InstallTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  alias Igniter.Project.TaskAliases
  alias Mix.Tasks.Soundcheck.Install

  test "installs soundcheck as a dev/test, non-runtime dependency" do
    info = Install.info([], nil)

    assert info.only == [:dev, :test]
    assert info.dep_opts[:runtime] == false
  end

  test "creates .credo.exs with the plugin when none exists" do
    test_project()
    |> Igniter.compose_task("soundcheck.install")
    |> assert_creates(".credo.exs")
  end

  test "adds the plugin to an existing plugins list once" do
    project =
      test_project(
        files: %{
          ".credo.exs" => """
          %{
            configs: [
              %{
                name: "default",
                plugins: [{OtherPlugin, []}]
              }
            ]
          }
          """
        }
      )

    project
    |> Igniter.compose_task("soundcheck.install")
    |> apply_igniter!()
    |> Igniter.compose_task("soundcheck.install")
    |> assert_unchanged(".credo.exs")
  end

  test "adds a lint alias that compiles before running Credo" do
    test_project()
    |> Igniter.compose_task("soundcheck.install")
    |> assert_has_patch("mix.exs", """
    31 + |    [lint: ["compile", "credo --strict"]]
    """)
  end

  test "leaves an existing lint alias alone and explains why compiling matters" do
    test_project()
    |> TaskAliases.add_alias(:lint, ["credo"])
    |> apply_igniter!()
    |> Igniter.compose_task("soundcheck.install")
    |> assert_unchanged("mix.exs")
    |> assert_has_notice(&(&1 =~ "compiles before running Credo"))
  end

  test "warns instead of crashing on a config it cannot navigate" do
    test_project(files: %{".credo.exs" => "configs = []\n%{configs: configs}\n"})
    |> Igniter.compose_task("soundcheck.install")
    |> assert_has_warning(&(&1 =~ "Could not add the Soundcheck plugin"))
  end
end
