defmodule Soundcheck.Check.AsyncAssignFieldReadTest do
  use Soundcheck.CheckCase

  import Soundcheck.HeexCase, only: [text_at: 2]

  alias Soundcheck.Check.Warning.AsyncAssignFieldRead

  @fixture "test/support/fixtures/async_assigns.ex"

  defp fixture, do: [{@fixture, File.read!(@fixture)}]

  test "fires on fields an AsyncResult lacks, including keys reset with AsyncResult" do
    diagnostics = analyze(AsyncAssignFieldRead, fixture())

    assert Enum.map(diagnostics, &text_at(File.read!(@fixture), &1.primary)) == [
             "@org.name",
             "@profile.bio"
           ]

    assert hd(diagnostics).suggestion =~ "`@org.result.name`"
  end

  test "near miss: AsyncResult fields, async_result slots, and plain assigns" do
    source = File.read!(@fixture)
    texts = analyze(AsyncAssignFieldRead, fixture()) |> Enum.map(&text_at(source, &1.primary))

    refute "@org.ok?" in texts
    refute "@org.result" in texts
    refute "@user.name" in texts
  end

  test "near miss: a key also assigned a plain value" do
    source = """
    defmodule MyAppWeb.OrgLive do
      use Phoenix.LiveView

      def mount(_params, _session, socket),
        do: {:ok, socket |> assign(:org, nil) |> assign_async(:org, fn -> {:ok, %{org: nil}} end)}

      def render(assigns), do: ~H"<h1>{@org.name}</h1>"
    end
    """

    assert [] = analyze(AsyncAssignFieldRead, source)
  end
end
