defmodule Soundcheck.Credo.BuildGraphTaskTest do
  use ExUnit.Case, async: true

  alias Credo.SourceFile
  alias Soundcheck.Credo.BuildGraphTask
  alias Soundcheck.PathFilter

  defp source_file(filename, source \\ "defmodule A do\nend\n"),
    do: SourceFile.parse(source, filename)

  defp files(inputs), do: Enum.map(inputs, & &1.file)

  describe "inputs/2" do
    test "keeps application sources and drops files under the excluded paths" do
      source_files = [
        source_file("lib/my_app_web/live/home_live.ex"),
        source_file("test/support/fixture_live.ex"),
        source_file("apps/web/lib/web/live/home_live.ex"),
        source_file("apps/web/test/support/fixture_live.ex")
      ]

      assert files(BuildGraphTask.inputs(source_files, PathFilter.default_excluded_paths())) ==
               ["lib/my_app_web/live/home_live.ex", "apps/web/lib/web/live/home_live.ex"]
    end

    test "near miss: a directory whose name only contains an excluded segment stays" do
      source_files = [source_file("lib/contest/entry_live.ex")]

      assert files(BuildGraphTask.inputs(source_files, PathFilter.default_excluded_paths())) ==
               ["lib/contest/entry_live.ex"]
    end

    test "no excluded paths keep every file" do
      source_files = [source_file("lib/a.ex"), source_file("test/support/b.ex")]

      assert files(BuildGraphTask.inputs(source_files, [])) ==
               ["lib/a.ex", "test/support/b.ex"]
    end

    test "drops files that do not parse" do
      source_files = [source_file("lib/a.ex"), source_file("lib/broken.ex", "defmodule A do")]

      assert files(BuildGraphTask.inputs(source_files, [])) == ["lib/a.ex"]
    end

    test "carries the source and the AST Credo parsed" do
      [input] = BuildGraphTask.inputs([source_file("lib/a.ex")], [])

      assert input.source == "defmodule A do\nend\n"
      assert {:defmodule, _meta, [{:__aliases__, _, [:A]}, _body]} = input.ast
    end
  end
end
