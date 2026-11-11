defmodule Soundcheck.Check.FormFieldMismatchTest do
  use Soundcheck.CheckCase

  import Soundcheck.HeexCase, only: [text_at: 2]

  alias Soundcheck.Check.Warning.FormFieldMismatch

  defp live(mount, form, handler) do
    """
    defmodule MyAppWeb.UserLive do
      use MyAppWeb, :live_view

      def mount(_params, _session, socket) do
        {:ok, assign(socket, :form, #{mount})}
      end

      def render(assigns) do
        ~H\"\"\"
    #{form}
        \"\"\"
      end

    #{handler}
    end
    """
  end

  @changeset "to_form(Accounts.change_user(%Accounts.User{}))"
  @form ~S"""
  <.form for={@form} phx-submit="save">
    <.input field={@form[:email]} />
  </.form>
  """
  @handler ~S"""
    def handle_event("save", %{"user" => %{"email" => email, "name" => name}}, socket) do
      {:noreply, socket}
    end
  """

  test "fires on a required key no field produces, naming the form from the schema struct" do
    source = live(@changeset, @form, @handler)
    assert [diagnostic] = analyze(FormFieldMismatch, source)
    assert diagnostic.message =~ ~s|requires `user[name]`|
    assert text_at(source, diagnostic.primary) == "def"
  end

  test "names the form from as:, and reads literal name attributes and :let" do
    form = ~S"""
    <.form :let={f} for={@form} phx-change="save">
      <.input field={f[:email]} />
      <input name="account[nickname]" />
    </.form>
    """

    handler = ~S"""
      def handle_event("save", %{"account" => %{"email" => _, "nickname" => _, "name" => _}}, s), do: s
    """

    assert [diagnostic] =
             analyze(FormFieldMismatch, live(~S|to_form(%{}, as: :account)|, form, handler))

    assert diagnostic.message =~ "`account[name]`"
  end

  test "near miss: every key produced, underscored keys, other form names" do
    form = ~S"""
    <.form for={@form} phx-submit="save">
      <.input field={@form[:email]} />
      <.input field={@form[:name]} />
    </.form>
    """

    assert [] = analyze(FormFieldMismatch, live(@changeset, form, @handler))

    underscored = ~S"""
      def handle_event("save", %{"user" => %{"email" => _, "_unused_email" => _}}, s), do: s
    """

    assert [] = analyze(FormFieldMismatch, live(@changeset, @form, underscored))

    other = ~S"""
      def handle_event("save", %{"post" => %{"title" => _}}, s), do: s
    """

    assert [] = analyze(FormFieldMismatch, live(@changeset, @form, other))
  end

  test "near miss: unresolved names and forms passed whole" do
    assert [] = analyze(FormFieldMismatch, live("to_form(changeset)", @form, @handler))

    passed = ~S"""
    <.form for={@form} phx-submit="save">
      <.input field={@form[:email]} />
      <.name_fields form={@form} />
    </.form>
    """

    assert [] = analyze(FormFieldMismatch, live(@changeset, passed, @handler))
  end
end
