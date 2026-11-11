defmodule Soundcheck.Check.ChangeTrackingTest do
  use Soundcheck.CheckCase

  import Soundcheck.HeexCase, only: [text_at: 2]

  alias Soundcheck.Check.Readability.AssignsDotAccess
  alias Soundcheck.Check.Refactor.BareAssignsInTemplate
  alias Soundcheck.Check.Refactor.TemplateBoundVariable

  defp component(template) do
    """
    defmodule MyAppWeb.Components do
      use Phoenix.Component

      def card(assigns) do
        ~H\"\"\"
    #{template}
        \"\"\"
      end
    end
    """
  end

  describe "BareAssignsInTemplate (SC301)" do
    test "fires on assigns passed to a helper or spread into a component" do
      source = component(~S|    <p>{format_title(assigns)}</p><.card {assigns} />|)
      diagnostics = analyze(BareAssignsInTemplate, source)

      assert ["assigns", "assigns"] = Enum.map(diagnostics, &text_at(source, &1.primary))
    end

    test "near miss: @key, assigns.key, and assigns[:key] are tracked" do
      source =
        component(~S|    <p>{format_title(@title)} {assigns.subtitle} {assigns[:extra]}</p>|)

      assert [] = analyze(BareAssignsInTemplate, source)
    end
  end

  describe "TemplateBoundVariable (SC303)" do
    test "fires on a template variable read afterwards" do
      source = component("    <% total = Enum.sum(@prices) %>\n    <p>Total: {total}</p>")
      assert [diagnostic] = analyze(TemplateBoundVariable, source)
      assert text_at(source, diagnostic.primary) == "total"
    end

    test "near miss: :for bindings and unread variables" do
      source = component("    <% _unused = 1 %>\n    <li :for={item <- @items}>{item}</li>")
      assert [] = analyze(TemplateBoundVariable, source)
    end
  end

  describe "AssignsDotAccess (SC302)" do
    test "fires on assigns.key" do
      source = component(~S|    <p>{assigns.title}</p>|)
      assert [diagnostic] = analyze(AssignsDotAccess, source)
      assert diagnostic.message == "Write `@title` instead of `assigns.title`."
      assert text_at(source, diagnostic.primary) == "assigns.title"
    end

    test "near miss: assigns[:key] differs from @key and is not reported" do
      assert [] = analyze(AssignsDotAccess, component(~S|    <p>{assigns[:title]}</p>|))
    end
  end
end
