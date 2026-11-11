defmodule Soundcheck.SuppressionTest do
  use Soundcheck.CheckCase, async: false

  alias Soundcheck.Check.Warning.UndeclaredComponentAttr
  alias Soundcheck.Suppression

  describe "directives/1" do
    test "reads Elixir, HEEx, and JavaScript comments with reasons" do
      source = """
      # soundcheck:disable-next-line SC101 -- pushed by a widget
      <%!-- soundcheck:disable-line SC1xx, UndefinedHook -- registered elsewhere --%>
      // soundcheck:disable-file SC103
      plain line
      """

      fields = &Map.take(&1, [:scope, :line, :column, :selectors, :reason])

      assert Enum.map(Suppression.directives(source), fields) == [
               %{
                 scope: :next_line,
                 line: 1,
                 column: 3,
                 selectors: ["SC101"],
                 reason: "pushed by a widget"
               },
               %{
                 scope: :line,
                 line: 2,
                 column: 7,
                 selectors: ["SC1xx", "UndefinedHook"],
                 reason: "registered elsewhere"
               },
               %{scope: :file, line: 3, column: 4, selectors: ["SC103"], reason: nil}
             ]
    end

    test "reads a directive without selectors" do
      assert [%{selectors: [], reason: "why"}] =
               Suppression.directives("# soundcheck:disable-next-line -- why")
    end

    test "in Elixir files, reads comments and ~H bodies but not docs or strings" do
      source = ~S'''
      defmodule MyApp.Docs do
        @moduledoc """
        # soundcheck:disable-file SC1xx
        """

        @hint "# soundcheck:disable-line SC101"

        # soundcheck:disable-next-line SC203
        def card(assigns) do
          ~H"""
          <%!-- soundcheck:disable-next-line SC204 --%>
          <p>{@title}</p>
          """
        end
      end
      '''

      assert [%{line: 8, selectors: ["SC203"]}, %{line: 11, selectors: ["SC204"]}] =
               Suppression.directives(source, "lib/my_app/docs.ex")
    end

    test "in files other than Elixir, reads every line" do
      assert [%{line: 1}] =
               Suppression.directives(~S|"// soundcheck:disable-file SC103"|, "assets/js/app.js")
    end
  end

  describe "selectors" do
    setup do
      %{
        diagnostic: %Soundcheck.Diagnostic{
          rule: Soundcheck.Check.Warning.UndefinedHook,
          id: "SC1001",
          message: "",
          primary: Soundcheck.Span.new("x", {1, 1}, {1, 2}),
          anchor: nil
        }
      }
    end

    test "match ids, family wildcards, and short names", %{diagnostic: diagnostic} do
      assert Suppression.matches?("SC1001", diagnostic)
      assert Suppression.matches?("SC1xx", diagnostic)
      assert Suppression.matches?("SC10xx", diagnostic)
      assert Suppression.matches?("UndefinedHook", diagnostic)
      refute Suppression.matches?("SC2xx", diagnostic)
      refute Suppression.matches?("SC100", diagnostic)
    end
  end

  @tag :tmp_dir
  test "a HEEx comment suppresses a finding on the next line, through Credo", %{tmp_dir: tmp_dir} do
    source = ~S'''
    defmodule MyAppWeb.Components do
      use Phoenix.Component

      attr :title, :string

      def card(assigns) do
        ~H"""
        <h2>{@subtitle}</h2>
        <%!-- soundcheck:disable-next-line SC203 -- passed by a legacy caller --%>
        <p>{@footer}</p>
        """
      end
    end
    '''

    file = Path.join(tmp_dir, "components.ex")
    File.write!(file, source)

    assert [issue] =
             run_check(UndeclaredComponentAttr, [{file, source}], file, excluded_paths: [])

    assert issue.message =~ "@subtitle"
  end

  @tag :tmp_dir
  test "an Elixir file directive suppresses every matching finding", %{tmp_dir: tmp_dir} do
    source = ~S'''
    # soundcheck:disable-file UndeclaredComponentAttr
    defmodule MyAppWeb.Components do
      use Phoenix.Component

      attr :title, :string
      def card(assigns), do: ~H"<h2>{@subtitle}</h2>"
    end
    '''

    file = Path.join(tmp_dir, "components.ex")
    File.write!(file, source)

    assert [] = run_check(UndeclaredComponentAttr, [{file, source}], file, excluded_paths: [])
  end
end
