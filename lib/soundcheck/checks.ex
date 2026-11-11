defmodule Soundcheck.Checks do
  @moduledoc false
  # Every soundcheck check. The Credo plugin's default config, `mix
  # soundcheck`, and the README's check table all read this list and each
  # check's `default?/0`, so they cannot drift apart.

  @checks [
    Soundcheck.Check.Design.UnusedEventHandler,
    Soundcheck.Check.Design.UnusedHook,
    Soundcheck.Check.Warning.EventPayloadMismatch,
    Soundcheck.Check.Warning.LiveViewCallbackInComponent,
    Soundcheck.Check.Warning.UnhandledEvent,
    Soundcheck.Check.Warning.UnhandledHookEvent,
    Soundcheck.Check.Warning.UnhandledServerPushEvent,
    Soundcheck.Check.Warning.UndefinedHook
  ]

  @doc "The `checks: %{extra: [...]}` entries for the plugin's default Credo config."
  @spec credo_config() :: String.t()
  def credo_config do
    entries =
      Enum.map_join(@checks, ",\n", fn check ->
        "          {#{inspect(check)}, #{if check.default?(), do: "[]", else: "false"}}"
      end)

    """
    %{
      configs: [
        %{
          name: "default",
          checks: %{
            extra: [
    #{entries}
            ]
          }
        }
      ]
    }
    """
  end
end
