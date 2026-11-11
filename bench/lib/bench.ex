defmodule Bench do
  @moduledoc """
  Paths shared by the corpus generator and the benchmark task.
  """

  @root Path.expand("..", __DIR__)

  @doc "The bench project's directory."
  @spec root() :: Path.t()
  def root, do: @root

  @doc "The directory the generator writes the corpus into."
  @spec corpus_dir() :: Path.t()
  def corpus_dir, do: Path.join(@root, "corpus")

  @doc "The directory of one corpus size."
  @spec size_dir(atom()) :: Path.t()
  def size_dir(size), do: Path.join(corpus_dir(), Atom.to_string(size))

  @doc "The glob of one corpus size's Elixir sources."
  @spec elixir_glob(atom()) :: Path.t()
  def elixir_glob(size), do: Path.join(size_dir(size), "lib/**/*.ex")

  @doc "The JavaScript directory of one corpus size."
  @spec js_dir(atom()) :: Path.t()
  def js_dir(size), do: Path.join(size_dir(size), "assets/js")

  @doc """
  The directory that holds the saved results for `tag`, under the repo's
  gitignored `tmp/`.
  """
  @spec results_dir(String.t()) :: Path.t()
  def results_dir(tag), do: Path.join([@root, "..", "tmp", "bench", tag]) |> Path.expand()
end
