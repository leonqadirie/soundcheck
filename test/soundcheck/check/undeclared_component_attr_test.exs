defmodule Soundcheck.Check.Warning.UndeclaredComponentAttrTest do
  use Soundcheck.CheckCase, async: false

  import Soundcheck.HeexCase, only: [text_at: 2]

  alias Soundcheck.Check.Warning.UndeclaredComponentAttr

  defp component(body) do
    """
    defmodule MyAppWeb.Components do
      use Phoenix.Component

    #{body}
    end
    """
  end

  test "fires on an undeclared @read in a component with declarations" do
    source =
      component(~S'''
        attr :title, :string, required: true

        def card(assigns) do
          ~H"""
          <h2>{@title}</h2><p>{@subtitle}</p>
          """
        end
      ''')

    assert [diagnostic] = analyze(UndeclaredComponentAttr, source)
    assert diagnostic.id == "SC203"

    assert diagnostic.message ==
             "`card/1` reads `@subtitle` but declares no `attr :subtitle` or `slot :subtitle`."

    assert text_at(source, diagnostic.primary) == "@subtitle"
  end

  test "near miss: the key is assigned in the body before rendering" do
    source =
      component(~S'''
        attr :title, :string, required: true

        def card(assigns) do
          assigns = assign(assigns, :subtitle, "x")
          ~H"<h2>{@title}</h2><p>{@subtitle}</p>"
        end
      ''')

    assert [] = analyze(UndeclaredComponentAttr, source)
  end

  test "counts slots, implicit assigns, keyword assigns, and piped assigns as declared" do
    source =
      component(~S'''
        attr :rest, :global
        slot :inner_block
        slot :footer

        def card(assigns) do
          assigns = assigns |> assign(count: 1) |> assign_new(:label, fn -> "x" end)
          ~H"<div {@rest}>{render_slot(@inner_block)}{render_slot(@footer)}{@count}{@label}{@__changed__}</div>"
        end
      ''')

    assert [] = analyze(UndeclaredComponentAttr, source)
  end

  test "skips components without declarations" do
    source = component(~S|  def card(assigns), do: ~H"<p>{@anything}</p>"|)
    assert [] = analyze(UndeclaredComponentAttr, source)
  end

  test "skips components that assign from a non-literal source" do
    source =
      component(~S'''
        attr :title, :string

        def card(assigns) do
          assigns = assign(assigns, defaults())
          ~H"<p>{@title}{@extra}</p>"
        end
      ''')

    assert [] = analyze(UndeclaredComponentAttr, source)
  end

  test "skips components the module calls directly" do
    source =
      component(~S'''
        attr :title, :string
        def card(assigns), do: ~H"<p>{@title}{@extra}</p>"

        def page(assigns), do: card(assigns)
      ''')

    assert [] = analyze(UndeclaredComponentAttr, source)
  end

  test "skips LiveComponent and LiveView renders, which read socket assigns" do
    source = ~S'''
    defmodule MyAppWeb.Panel do
      use MyAppWeb, :live_component

      attr :id, :string, required: true

      def update(assigns, socket), do: {:ok, assign(socket, assigns) |> assign(:open?, false)}
      def render(assigns), do: ~H"<div id={@id} phx-target={@myself}>{@open?}</div>"
    end
    '''

    assert [] = analyze(UndeclaredComponentAttr, source)
  end

  test "skips components that rebind assigns through another function" do
    source =
      component(~S'''
        slot :col, required: true

        def row(assigns) do
          assigns = validate_columns(assigns)
          ~H"<div class={@columns_class}>{render_slot(@col)}</div>"
        end
      ''')

    assert [] = analyze(UndeclaredComponentAttr, source)
  end

  test "reports each key once per template" do
    source =
      component(~S'''
        attr :title, :string
        def card(assigns), do: ~H"<p>{@extra}{@extra}</p><i class={@extra}></i>"
      ''')

    assert [_one] = analyze(UndeclaredComponentAttr, source)
  end

  test "honors implicit_assigns" do
    source =
      component(~S'''
        attr :title, :string
        def card(assigns), do: ~H"<p>{@flash}</p>"
      ''')

    assert [] = analyze(UndeclaredComponentAttr, source, implicit_assigns: [:flash])
  end

  describe "through Credo" do
    test "projects the diagnostic onto an issue at the read" do
      source =
        component(~S'''
          attr :title, :string
          def card(assigns), do: ~H"<p>{@subtitle}</p>"
        ''')

      assert [issue] = run_check(UndeclaredComponentAttr, source)
      assert issue.filename == "lib/demo.ex"
      assert issue.line_no == 5
      assert issue.message =~ "(SC203)"
      assert %{soundcheck: %Soundcheck.Diagnostic{id: "SC203"}} = Map.new(issue.meta)
    end

    test "returns only the issues anchored in the file Credo asks about" do
      other = component(~S|  attr :a, :string
  def card(assigns), do: ~H"<p>{@b}</p>"|)
      clean = "defmodule Clean do\nend\n"

      sources = [{"lib/other.ex", other}, {"lib/clean.ex", clean}]

      assert [] = run_check(UndeclaredComponentAttr, sources, "lib/clean.ex")
      assert [_issue] = run_check(UndeclaredComponentAttr, sources, "lib/other.ex")
    end

    test "skips excluded paths" do
      source = component(~S|  attr :a, :string
  def card(assigns), do: ~H"<p>{@b}</p>"|)

      assert [] =
               run_check(
                 UndeclaredComponentAttr,
                 [{"test/support/demo.ex", source}],
                 "test/support/demo.ex"
               )
    end
  end
end
