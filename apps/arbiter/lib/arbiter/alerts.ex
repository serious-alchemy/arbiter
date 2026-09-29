defmodule Arbiter.Alerts do
  @moduledoc """
  System alerts (ticket lifecycle 8/13, bd-7gt8rm): problems with the
  installation that are not tied to a ticket, and clear when their condition
  clears. See `Arbiter.Alerts.SystemAlert` for the record and
  `docs/design/ticket-lifecycle.md` ("Child 8") for who raises and clears
  each kind.

    * `raise_alert/1` opens an alert, or — while one of the same `(kind, key)`
      is active — refreshes that row's subject, detail and `last_raised_at`
      instead of adding a second.
    * `clear/2` and `clear_except/2` stamp `cleared_at` once the producer sees
      the condition healthy again. A later raise opens a fresh episode.
    * `active/1` lists what is still active, oldest first — the read behind
      `GET /api/alerts` and the MCP `alert_list` tool.

  Every raise, refresh and clear is announced on the workspace's `inbox` event
  topic as `%{kind: "alert", event: "raised" | "refreshed" | "cleared", …}`.
  """

  use Ash.Domain

  require Ash.Query
  require Logger

  alias Arbiter.Alerts.SystemAlert

  resources do
    resource SystemAlert
  end

  @type attrs :: %{
          required(:kind) => atom(),
          required(:key) => String.t(),
          optional(:workspace_id) => String.t() | nil,
          optional(:subject) => String.t() | nil,
          optional(:detail) => String.t(),
          optional(:owner) => :operator | :coordinator
        }

  @doc """
  Raise an alert. `attrs` takes `:kind` (one of `SystemAlert.kinds/0`),
  `:key`, and optionally `:workspace_id`, `:subject`, `:detail` and `:owner`
  (default `:operator`).

  Returns `{:ok, alert}` — the new row, or the active one it refreshed — or
  `{:error, reason}`.
  """
  @spec raise_alert(attrs()) :: {:ok, SystemAlert.t()} | {:error, term()}
  def raise_alert(%{kind: kind, key: key} = attrs) when is_binary(key) do
    case active_row(kind, key) do
      nil -> open(attrs)
      row -> refresh(row, attrs)
    end
  end

  defp open(%{kind: kind, key: key} = attrs) do
    fields = Map.take(attrs, [:kind, :key, :workspace_id, :subject, :detail, :owner])

    case Ash.create(SystemAlert, fields, action: :raise) do
      {:ok, alert} ->
        announce(alert, :raised)
        {:ok, alert}

      {:error, _} = error ->
        # Another process may have opened the same episode between the read
        # and the insert — the partial unique index refused ours. Fold into
        # theirs.
        case active_row(kind, key) do
          nil -> error
          row -> refresh(row, attrs)
        end
    end
  end

  defp refresh(row, attrs) do
    changes =
      attrs
      |> Map.take([:subject, :detail])
      |> Map.reject(fn {_k, v} -> is_nil(v) end)

    with {:ok, alert} <- Ash.update(row, changes, action: :refresh) do
      announce(alert, :refreshed)
      {:ok, alert}
    end
  end

  @doc """
  Clear the active `(kind, key)` alert. Returns `{:ok, cleared}` — an empty
  list when nothing was active, so a routine healthy check costs one read.
  """
  @spec clear(atom(), String.t()) :: {:ok, [SystemAlert.t()]} | {:error, term()}
  def clear(kind, key) when is_binary(key) do
    SystemAlert
    |> Ash.Query.filter(kind == ^kind and key == ^key and is_nil(cleared_at))
    |> clear_all()
  end

  @doc """
  Clear every active alert of `kind` whose key is not in `keep` — for a
  producer that assesses the whole set at once (the budget patrol).
  """
  @spec clear_except(atom(), [String.t()]) :: {:ok, [SystemAlert.t()]} | {:error, term()}
  def clear_except(kind, keep) when is_list(keep) do
    SystemAlert
    |> Ash.Query.filter(kind == ^kind and is_nil(cleared_at))
    |> Ash.read!()
    |> Enum.reject(&(&1.key in keep))
    |> clear_rows()
  end

  defp clear_all(query), do: query |> Ash.read!() |> clear_rows()

  defp clear_rows(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, acc} ->
      case Ash.update(row, %{}, action: :clear) do
        {:ok, cleared} ->
          announce(cleared, :cleared)
          {:cont, {:ok, acc ++ [cleared]}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  @doc """
  Active alerts, oldest first. Options: `:workspace_id`, `:kind`.
  """
  @spec active(keyword()) :: [SystemAlert.t()]
  def active(opts \\ []) do
    SystemAlert
    |> Ash.Query.filter(is_nil(cleared_at))
    |> filter_opt(:workspace_id, Keyword.get(opts, :workspace_id))
    |> filter_opt(:kind, Keyword.get(opts, :kind))
    |> Ash.Query.sort(raised_at: :asc, id: :asc)
    |> Ash.read!()
  end

  defp filter_opt(query, _field, nil), do: query

  defp filter_opt(query, :workspace_id, ws_id),
    do: Ash.Query.filter(query, workspace_id == ^ws_id)

  defp filter_opt(query, :kind, kind), do: Ash.Query.filter(query, kind == ^kind)

  defp active_row(kind, key) do
    SystemAlert
    |> Ash.Query.filter(kind == ^kind and key == ^key and is_nil(cleared_at))
    |> Ash.read_one!()
  end

  @doc "The JSON shape `GET /api/alerts` and MCP `alert_list` return."
  @spec serialize(SystemAlert.t()) :: map()
  def serialize(%SystemAlert{} = alert) do
    %{
      id: alert.id,
      kind: Atom.to_string(alert.kind),
      key: alert.key,
      workspace_id: alert.workspace_id,
      subject: alert.subject,
      detail: alert.detail,
      owner: Atom.to_string(alert.owner),
      raised_at: iso(alert.raised_at),
      last_raised_at: iso(alert.last_raised_at),
      raise_count: alert.raise_count,
      cleared_at: iso(alert.cleared_at)
    }
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)

  defp announce(%SystemAlert{} = alert, event) do
    Arbiter.Events.broadcast(alert.workspace_id, "inbox", %{
      kind: "alert",
      event: Atom.to_string(event),
      alert_id: alert.id,
      alert_kind: Atom.to_string(alert.kind),
      key: alert.key,
      subject: alert.subject,
      owner: Atom.to_string(alert.owner)
    })
  rescue
    e ->
      Logger.debug("Alerts.announce/2 swallowed: #{Exception.message(e)}")
      :ok
  end
end
