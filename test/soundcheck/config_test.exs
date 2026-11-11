defmodule Soundcheck.ConfigTest do
  use ExUnit.Case, async: true

  alias Soundcheck.Check.Design.UnusedHook
  alias Soundcheck.Check.Warning.UndefinedHook
  alias Soundcheck.Check.Warning.UnhandledEvent
  alias Soundcheck.Config

  test "reads soundcheck checks and plugin params from a checks map" do
    data = %{
      configs: [
        %{name: "ci", checks: []},
        %{
          name: "default",
          plugins: [{OtherPlugin, []}, {Soundcheck, [js_paths: ["web/js"]]}],
          checks: %{
            enabled: [{Credo.Check.Readability.ModuleDoc, []}],
            extra: [{UnhandledEvent, [ignore_events: ["ping"]]}, {UnusedHook, []}],
            disabled: [{UndefinedHook, []}]
          }
        }
      ]
    }

    config = Config.from_data(data, "default")

    assert config.plugin == [js_paths: ["web/js"]]
    assert Config.params(config, UnhandledEvent) == [ignore_events: ["ping"]]
    assert config.checks[UndefinedHook] == false
    refute Map.has_key?(config.checks, Credo.Check.Readability.ModuleDoc)
  end

  test "reads a plain checks list" do
    config =
      Config.from_data(
        %{configs: [%{name: "default", checks: [{UndefinedHook, false}]}]},
        "default"
      )

    assert config.checks == %{UndefinedHook => false}
  end

  test "selected/2 adds enabled checks and removes disabled ones" do
    config = %Config{checks: %{UnusedHook => [], UndefinedHook => false}, plugin: []}

    assert Config.selected(config, [UnhandledEvent, UndefinedHook]) == [
             UnhandledEvent,
             UnusedHook
           ]
  end

  test "a missing file or config name is empty" do
    assert Config.read("does/not/exist.exs") == %Config{}
    assert Config.from_data(%{configs: []}, "default") == %Config{}
  end
end
