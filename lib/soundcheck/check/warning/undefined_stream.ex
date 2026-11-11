defmodule Soundcheck.Check.Warning.UndefinedStream do
  use Soundcheck.Check,
    id: "SC310",
    base_priority: :high,
    category: :warning,
    confidence: :medium,
    tier: :syntactic,
    default: false,
    summary:
      "`@streams.name` reads and `stream_insert`/`stream_delete` calls on stream names the module never defines",
    explanations: [
      check: """
      Flags stream names a LiveView or LiveComponent uses but never
      defines. `@streams` holds only the streams that `stream/4` or
      `stream_async/4` created, so a template reading `@streams.post` when
      the module streams `:posts` raises `KeyError` on render, and
      `stream_insert/4`, `stream_delete/3`, or `stream_delete_by_dom_id/3`
      on an unknown name raises `ArgumentError`.

      Before:

          def mount(_params, _session, socket),
            do: {:ok, stream(socket, :posts, Blog.list_posts())}

          <div id="posts" phx-update="stream">
            <div :for={{id, post} <- @streams.post} id={id}>{post.title}</div>
          </div>

      After:

          <div :for={{id, post} <- @streams.posts} id={id}>{post.title}</div>

      Definitions are `stream/3,4`, `stream_async/3,4`, and
      `stream_configure/3` calls with a literal atom name in the module's
      own functions and in the project functions it calls, through remote
      calls and imports at any depth. Reads come from its `render/1`
      template, colocated or inline. The check skips a module when it and
      those functions define no stream, when any of them names one
      dynamically, or when it passes its socket to a function outside the
      project and Phoenix, since that function may define streams the
      check cannot see.
      """
    ]

  alias Soundcheck.Analysis.SocketNames
  alias Soundcheck.Diagnostic
  alias Soundcheck.Graph

  @streams %{
    assign: :streams,
    defining: [:stream, :stream_async, :stream_configure],
    using: [:stream_insert, :stream_delete, :stream_delete_by_dom_id]
  }

  @impl Soundcheck.Rule
  def analyze(%Graph{} = graph, _params) do
    for %{entry: entry, name: name, defined: defined, span: span, anchor: anchor} <-
          SocketNames.undefined(graph, @streams) do
      Diagnostic.new(
        __MODULE__,
        span,
        "`#{inspect(entry.name)}` uses the stream #{inspect(name)} but defines only " <>
          "#{Enum.map_join(defined, ", ", &inspect/1)}, so LiveView raises.",
        suggestion: SocketNames.suggestion(name, defined),
        anchor: anchor
      )
    end
  end
end
