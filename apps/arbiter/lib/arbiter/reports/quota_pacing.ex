defmodule Arbiter.Reports.QuotaPacing do
  @moduledoc """
  Quota utilization against the pace ceiling, per account and window, for
  `/reports` (bd-5kt9sk; design `docs/design/reports-design-v2.md` §9 row 12).

  Reads the append-only `Arbiter.Quota.QuotaSnapshot` history. Polls land every
  few minutes, so each window's series is reduced to the last sample of every
  hour and capped at the most recent `max_points/0` hours. Quota is an account
  limit, so the workspace/repo/type filters do not apply; only the range does.
  """

  import Ecto.Query

  alias Arbiter.Repo

  @max_points 168

  @doc "Most points kept per window series."
  def max_points, do: @max_points

  @doc """
  `[%{account_id, provider, label, windows: [%{window, points}]}]`, where a point
  is `%{key, label, value, ceiling}` (percent). Accounts with no history are
  absent.
  """
  @spec load(String.t(), DateTime.t()) :: [map()]
  def load(range \\ "all", now \\ DateTime.utc_now()) do
    from(s in "quota_snapshots",
      join: a in "provider_accounts",
      on: a.id == s.provider_account_id,
      where: ^since(range, now),
      order_by: [s.provider_account_id, s.window, s.captured_at],
      select: %{
        account_id: type(s.provider_account_id, :string),
        provider: s.provider,
        slug: a.slug,
        window: s.window,
        utilization: s.utilization,
        ceiling: s.ceiling,
        at: type(s.captured_at, :utc_datetime)
      }
    )
    |> Repo.all()
    |> Enum.group_by(&{&1.account_id, &1.provider, &1.slug})
    |> Enum.sort_by(fn {{_, provider, slug}, _} -> {provider, slug} end)
    |> Enum.map(fn {{id, provider, slug}, rows} ->
      windows =
        rows
        |> Enum.group_by(& &1.window)
        |> Enum.sort_by(fn {w, _} -> w end)
        |> Enum.map(fn {w, ws} -> %{window: w, points: points(ws)} end)

      %{account_id: id, provider: provider, label: "#{provider}/#{slug}", windows: windows}
    end)
  end

  defp since("all", _now), do: dynamic(true)

  defp since(range, now) do
    days = range |> String.trim_trailing("d") |> String.to_integer()
    cutoff = DateTime.add(now, -days * 86_400, :second)
    dynamic([s], s.captured_at >= ^cutoff)
  end

  @doc false
  def points(rows) do
    rows
    |> Enum.chunk_by(&hour/1)
    |> Enum.map(&List.last/1)
    |> Enum.take(-@max_points)
    |> Enum.map(fn r ->
      %{
        key: DateTime.to_iso8601(r.at),
        label: Calendar.strftime(r.at, "%b %d %Hh"),
        value: pct(r.utilization),
        ceiling: r.ceiling && pct(r.ceiling)
      }
    end)
  end

  defp hour(%{at: at}), do: {DateTime.to_date(at), at.hour}
  defp pct(v), do: Float.round(v * 100, 1)
end
