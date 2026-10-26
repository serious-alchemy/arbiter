defmodule Arbiter.Worker.Image.PublishLedger do
  @moduledoc """
  Which repos published a run image, and when (SI2, `docs/design/remote-workers.md`
  §21.9): the `Arbiter.Worker.CliSet.Watcher` republishes the ones that published
  in the last 14 days when the CLI set moves.

  One entry per repo (`{repo, repo_path}`), holding the publish context
  (`Image.Publisher.ensure_ready/2`'s `ctx`, plan included) of the newest
  successful publish and its time. It lives in a file under the image root so a
  restart does not forget it; the Publisher only records into it when its
  `:ledger` option, or `config :arbiter, :image_publisher, ledger: path`, names a
  file (default `<image root>/publish-ledger.term`; the test suite sets it to
  `nil`).
  """

  alias Arbiter.Config.Paths

  @type entry :: %{key: term(), ctx: map(), at: DateTime.t()}

  @doc "The ledger file, or `nil` when recording is off."
  @spec path(keyword()) :: Path.t() | nil
  def path(opts \\ []) do
    case Keyword.fetch(opts, :ledger) do
      {:ok, path} ->
        path

      :error ->
        :arbiter
        |> Application.get_env(:image_publisher, [])
        |> Keyword.get_lazy(:ledger, fn ->
          Path.join(Paths.image_root(), "publish-ledger.term")
        end)
    end
  end

  @doc "Note that `ctx`'s repo published just now. A no-op while the ledger is off."
  @spec record(map(), keyword()) :: :ok
  def record(ctx, opts \\ []) do
    case path(opts) do
      nil ->
        :ok

      file ->
        now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
        key = {Map.get(ctx, :repo), Map.get(ctx, :repo_path)}

        :global.trans({{__MODULE__, file}, self()}, fn ->
          entries = Map.put(read(file), key, %{key: key, ctx: ctx, at: now})
          write(file, entries)
        end)

        :ok
    end
  end

  @doc "The entries recorded within the last `days` days, newest first."
  @spec recent(non_neg_integer(), keyword()) :: [entry()]
  def recent(days, opts \\ []) do
    case path(opts) do
      nil ->
        []

      file ->
        now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
        cutoff = DateTime.add(now, -days * 86_400, :second)

        file
        |> read()
        |> Map.values()
        |> Enum.filter(&(DateTime.compare(&1.at, cutoff) != :lt))
        |> Enum.sort_by(& &1.at, {:desc, DateTime})
    end
  end

  defp read(file) do
    with {:ok, bin} <- File.read(file),
         %{} = entries <- safe_decode(bin) do
      entries
    else
      _ -> %{}
    end
  end

  defp safe_decode(bin) do
    :erlang.binary_to_term(bin, [:safe])
  rescue
    ArgumentError -> nil
  end

  defp write(file, entries) do
    File.mkdir_p!(Path.dirname(file))
    tmp = file <> ".tmp#{System.unique_integer([:positive])}"
    File.write!(tmp, :erlang.term_to_binary(entries))
    File.rename!(tmp, file)
  end
end
