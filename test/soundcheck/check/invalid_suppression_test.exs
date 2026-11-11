defmodule Soundcheck.Check.InvalidSuppressionTest do
  use Soundcheck.CheckCase

  import Soundcheck.HeexCase, only: [text_at: 2]

  alias Soundcheck.Check.Readability.InvalidSuppression

  @moduletag :tmp_dir

  # Suppression comments are read from disk, as in a real run.
  defp analyze_file(tmp_dir, comments, params \\ []) do
    file = Path.join(tmp_dir, "live.ex")

    source = """
    defmodule MyAppWeb.FeedLive do
      use MyAppWeb, :live_view
    #{comments}
      def mount(_params, _session, socket), do: {:ok, socket}
    end
    """

    File.write!(file, source)
    {source, analyze(InvalidSuppression, [{file, source}], params)}
  end

  test "fires on unknown ids and names, with a suggestion", %{tmp_dir: tmp_dir} do
    {source, diagnostics} =
      analyze_file(tmp_dir, "  # soundcheck:disable-next-line SC1O1, UnhandledEvnt -- legacy")

    assert [unknown_id, unknown_name] = diagnostics
    assert unknown_id.message =~ "`SC1O1` matches no soundcheck rule"
    assert unknown_id.message =~ "Did you mean `SC101`?"
    assert unknown_name.message =~ "Did you mean `UnhandledEvent`?"
    assert text_at(source, unknown_id.primary) =~ ~r/^soundcheck:disable-next-line SC1O1/
  end

  test "fires on a directive without selectors", %{tmp_dir: tmp_dir} do
    {_source, diagnostics} = analyze_file(tmp_dir, "  # soundcheck:disable-next-line -- why")
    assert [%{message: "This suppression names no rule" <> _}] = diagnostics
  end

  test "near miss: ids, family wildcards, and short names", %{tmp_dir: tmp_dir} do
    {_source, diagnostics} =
      analyze_file(
        tmp_dir,
        "  # soundcheck:disable-file SC101, SC1xx, UndefinedHook -- generated"
      )

    assert diagnostics == []
  end

  test "strict reports suppressions without a reason", %{tmp_dir: tmp_dir} do
    comment = "  # soundcheck:disable-next-line SC101"
    assert {_source, []} = analyze_file(tmp_dir, comment)

    assert {_source, [%{message: "This suppression gives no reason" <> _}]} =
             analyze_file(tmp_dir, comment, strict: true)
  end
end
