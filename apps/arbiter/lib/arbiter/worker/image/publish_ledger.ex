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

  @type entry :: %{key: term(), ctx: map(), at: DateTime.t(), ref: String.t() | nil}

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
          entry = %{
            key: key,
            ctx: ctx,
            at: now,
            ref: Keyword.get(opts, :ref),
            image: Keyword.get(opts, :image)
          }

          entries = Map.put(read(file), key, entry)
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

  @doc """
  SI7: the digest-pinned ref `repo`'s newest successful publish produced, or `nil` (never
  published, a publish before refs were recorded, or the ledger off). What warm-first
  placement looks for in a node's `hb.images`.
  """
  @spec last_ref(String.t() | nil, keyword()) :: String.t() | nil
  def last_ref(repo, opts \\ [])

  def last_ref(repo, opts) when is_binary(repo) do
    case path(opts) do
      nil ->
        nil

      file ->
        file
        |> read()
        |> Map.values()
        |> Enum.filter(&(elem(&1.key, 0) == repo and is_binary(Map.get(&1, :ref))))
        |> Enum.max_by(& &1.at, DateTime, fn -> nil end)
        |> case do
          nil -> nil
          entry -> entry.ref
        end
    end
  end

  def last_ref(_repo, _opts), do: nil

  @doc """
  SI11: per repo, its newest publish as the doctor's `image <repo>` row shows it:
  `%{repo, ref, at, providers, clis, seed}` (the last three are `nil` for a publish
  recorded before they were kept). `[]` while the ledger is off.
  """
  @spec images(keyword()) :: [map()]
  def images(opts \\ []) do
    case path(opts) do
      nil ->
        []

      file ->
        file
        |> read()
        |> Map.values()
        |> Enum.filter(&(is_binary(elem(&1.key, 0)) and is_binary(Map.get(&1, :ref))))
        |> Enum.group_by(&elem(&1.key, 0))
        |> Enum.map(fn {_repo, entries} -> Enum.max_by(entries, & &1.at, DateTime) end)
        |> Enum.sort_by(&elem(&1.key, 0))
        |> Enum.map(fn entry ->
          image = Map.get(entry, :image) || %{}

          %{
            repo: elem(entry.key, 0),
            ref: entry.ref,
            at: entry.at,
            providers: Map.get(image, :providers),
            clis: Map.get(image, :clis),
            seed: Map.get(image, :seed)
          }
        end)
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

  # sobelow_skip ["Misc.BinToTerm"]
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
