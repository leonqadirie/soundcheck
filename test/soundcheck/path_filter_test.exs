defmodule Soundcheck.PathFilterTest do
  use ExUnit.Case, async: true

  import Soundcheck.PathFilter

  test "binary entries match whole path segments" do
    assert excluded?("test/foo_test.exs", ["test"])
    assert excluded?("/repo/test/foo_test.exs", ["test"])
    assert excluded?("test", ["test"])
    refute excluded?("contest/foo.ex", ["test"])
    refute excluded?("lib/testing.ex", ["test"])
  end

  test "trailing slashes are ignored and an empty entry matches nothing" do
    assert excluded?("test/foo.exs", ["test/"])
    refute excluded?("lib/foo.ex", ["/"])
    refute excluded?("lib/foo.ex", [""])
  end

  test "binary entries can name a single file" do
    assert excluded?("priv/repo/seeds.exs", ["priv/repo/seeds.exs"])
    refute excluded?("priv/repo/seeds_extra.exs", ["priv/repo/seeds.exs"])
  end

  test "regex entries match the full filename" do
    assert excluded?("lib/my_app_web/live/admin/index.ex", [~r"/admin/"])
    refute excluded?("lib/my_app_web/live/index.ex", [~r"/admin/"])
  end

  test "the default excludes test directories only" do
    assert excluded?("test/support/fixtures.ex", default_excluded_paths())
    assert excluded?("/repo/apps/web/test/x.exs", default_excluded_paths())
    refute excluded?("lib/my_app_web/live/index.ex", default_excluded_paths())
  end
end
