defmodule Soundcheck.Graph.InputTest do
  # `File.cd!/2` changes the directory of the whole VM.
  use ExUnit.Case, async: false

  alias Soundcheck.Graph.Input

  @module "defmodule A do\nend\n"

  defp write(root, files) do
    for {path, source} <- files do
      file = Path.join(root, path)
      File.mkdir_p!(Path.dirname(file))
      File.write!(file, source)
    end
  end

  describe "default_globs/0" do
    @tag :tmp_dir
    test "match a project's and an umbrella's application sources, not their tests",
         %{tmp_dir: tmp_dir} do
      write(tmp_dir, [
        {"lib/my_app/accounts.ex", @module},
        {"web/live/home_live.ex", @module},
        {"apps/shop/lib/shop.ex", @module},
        {"apps/shop_web/web/live/cart_live.ex", @module},
        {"test/support/fixture_live.ex", @module},
        {"apps/shop/test/support/fixture_live.ex", @module},
        {"lib/my_app/accounts.exs", @module},
        {"priv/repo/seeds.ex", @module}
      ])

      {inputs, unparsable} = File.cd!(tmp_dir, fn -> Input.load(Input.default_globs()) end)

      assert Enum.map(inputs, & &1.file) == [
               "apps/shop/lib/shop.ex",
               "apps/shop_web/web/live/cart_live.ex",
               "lib/my_app/accounts.ex",
               "web/live/home_live.ex"
             ]

      assert unparsable == []
    end
  end

  describe "load/1" do
    @tag :tmp_dir
    test "reports the files that do not parse and reads a file two globs match once",
         %{tmp_dir: tmp_dir} do
      write(tmp_dir, [{"lib/a.ex", @module}, {"lib/broken.ex", "defmodule A do"}])

      {inputs, unparsable} =
        File.cd!(tmp_dir, fn -> Input.load(["lib/**/*.ex", "lib/a.ex"]) end)

      assert [%Input{file: "lib/a.ex", source: @module}] = inputs
      assert unparsable == ["lib/broken.ex"]
    end
  end
end
