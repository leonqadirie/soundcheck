defmodule Smoke.Components do
  @moduledoc false
  use Phoenix.Component

  attr(:title, :string, required: true)

  def card(assigns) do
    ~H"""
    <h2>{@title}</h2>
    <p>{@subtitle}</p>
    """
  end
end
