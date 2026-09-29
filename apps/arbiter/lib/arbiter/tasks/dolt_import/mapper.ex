defmodule Arbiter.Tasks.DoltImport.Mapper do
  @moduledoc """
  Pure field-mapping functions for the Dolt-to-Postgres import task.

  Separated from the mix task so we can unit-test the conversions without
  needing a live Dolt DB.
  """

  alias Arbiter.Tasks.Dependency
  alias Arbiter.Tasks.Issue

  @valid_dep_types Dependency
                   |> then(fn _ ->
                     [:blocks, :depends_on, :relates_to, :discovered_from, :parent_of]
                   end)

  @doc """
  Map a Dolt row's `status` string to an atom: `:open`, `:closed`, or
  `:in_progress` for anything else. The Dolt status is external data; the
  ticket itself only ever stores the lifecycle `state` it implies
  (`state_for/1`).
  """
  def map_status("open"), do: :open
  def map_status("closed"), do: :closed
  def map_status(_), do: :in_progress

  @doc """
  The lifecycle state an imported Dolt row lands in: an open row is
  `:backlog` (Dolt has no notion of a refined ticket), an in-progress one
  `:active`, a closed one `:closed`.
  """
  def state_for(:open), do: :backlog
  def state_for(:in_progress), do: :active
  def state_for(:closed), do: :closed

  @doc "Map a Dolt `issue_type` string to an Ash Issue issue_type atom, defaulting to :task for unknown values."
  def map_issue_type(t) when is_binary(t) do
    valid = Issue.issue_types() |> Enum.map(&Atom.to_string/1)

    if t in valid do
      String.to_existing_atom(t)
    else
      :task
    end
  end

  def map_issue_type(_), do: :task

  @doc "Clamp / default priority to the [0, 4] range. Default 2."
  def parse_priority(p) when is_integer(p) and p in 0..4, do: p
  def parse_priority(p) when is_integer(p) and p > 4, do: 4
  def parse_priority(p) when is_integer(p) and p < 0, do: 0
  def parse_priority(_), do: 2

  @doc """
  Parse a Dolt `external_ref` like `"jira-AX-17585"` into a
  `{tracker_type, tracker_ref}` tuple.

  Returns `{:none, nil}` for missing / empty / unknown formats.
  """
  def parse_external_ref(nil), do: {:none, nil}
  def parse_external_ref(""), do: {:none, nil}

  def parse_external_ref(ref) when is_binary(ref) do
    case String.split(ref, "-", parts: 2) do
      ["jira", id] -> {:jira, id}
      ["linear", id] -> {:linear, id}
      ["gh", id] -> {:github, id}
      ["github", id] -> {:github, id}
      _ -> {:none, nil}
    end
  end

  @doc "Map a Dolt dependency type string (e.g. \"discovered-from\") to an Ash atom, or nil if unrecognized."
  def map_dep_type(s) when is_binary(s) do
    normalized = s |> String.replace("-", "_") |> String.downcase()

    Enum.find(@valid_dep_types, fn t -> Atom.to_string(t) == normalized end)
  end

  def map_dep_type(_), do: nil

  @doc "Convert nil and \"\" to nil; pass other strings through."
  def nonempty(nil), do: nil
  def nonempty(""), do: nil
  def nonempty(s) when is_binary(s), do: s
  def nonempty(_), do: nil

  @doc """
  Parse a Dolt-formatted datetime string (`"2026-05-19 19:21:46.123456"`) to a
  `DateTime` in UTC. Returns `nil` for nil / empty / unparseable inputs.
  """
  def parse_dt(nil), do: nil
  def parse_dt(""), do: nil

  def parse_dt(s) when is_binary(s) do
    iso = String.replace(s, " ", "T") <> "Z"

    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> DateTime.truncate(dt, :microsecond)
      _ -> nil
    end
  end

  def parse_dt(_), do: nil

  @doc """
  Compose the final `description` from Dolt's `description` and `design` fields.
  If `design` is non-empty, append it as a `## Design` section.
  """
  def compose_description(row) when is_map(row) do
    desc = Map.get(row, "description") || ""
    design = Map.get(row, "design") || ""

    cond do
      design == "" -> desc
      desc == "" -> "## Design\n\n#{design}"
      true -> "#{desc}\n\n## Design\n\n#{design}"
    end
  end

  @doc """
  Derive a workspace prefix from a list of Dolt issue rows by taking the prefix
  of the first row's id (e.g. \"hq-3o8\" → `\"hq\"`).
  """
  def derive_prefix([%{"id" => id} | _]) when is_binary(id) do
    id |> String.split("-", parts: 2) |> List.first() |> String.downcase()
  end

  def derive_prefix(_), do: "ar"

  # ---- Row -> record (the shapes `Repo.insert_all/3` receives) ----
  #
  # These bypass Ash, so nothing normalises ids for us. On SQLite every id
  # column is plain `:text`: the adapter stores exactly the bytes it is handed
  # and hands the same bytes back, and Ash's non-strict load keeps a value its
  # type rejects rather than failing the read. Both ids below must therefore be
  # the hyphenated *string* Ash itself writes — a 16-byte `Ecto.UUID.dump!/1`
  # or `Ash.UUIDv7.bingenerate/0` value lands as opaque text that no
  # `Ash.get/2` can find and no foreign key can match
  # (`Arbiter.Tasks.DoltImport.RecordsTest`).

  @doc false
  def issue_record(row, workspace_id, now) do
    {tracker_type, tracker_ref} = parse_external_ref(row["external_ref"])
    status = map_status(row["status"])

    %{
      id: row["id"],
      workspace_id: workspace_id,
      title: nonempty(row["title"]) || "(untitled)",
      description: compose_description(row),
      acceptance: row["acceptance_criteria"] || "",
      notes: row["notes"] || "",
      qa_notes: "",
      deployment_notes: "",
      # bd-842qio: written around Ash, so nothing else sets the lifecycle
      # state the Dolt status implies (an open row is backlog — Dolt has no
      # notion of a refined ticket). Ecto.insert_all needs the raw DB type, so
      # the atom goes in as a string. `rank` stays at the column's 0 — an
      # imported ticket predates everything created here.
      state: Atom.to_string(state_for(status)),
      close_reason: if(status == :closed, do: "completed"),
      priority: parse_priority(row["priority"]),
      issue_type: Atom.to_string(map_issue_type(row["issue_type"])),
      tracker_type: Atom.to_string(tracker_type),
      tracker_ref: tracker_ref,
      created_at: parse_dt(row["created_at"]) || now,
      updated_at: parse_dt(row["updated_at"]) || now,
      closed_at: parse_dt(row["closed_at"])
    }
  end

  # The `--sync-status` refresh of an existing row. `state` and `close_reason`
  # follow the Dolt status, in SQL because an in-progress row reads the
  # ticket's own `pr_ref` / `pending_merge` (either one means `merging`). An open Dolt row leaves a
  # backlog or queued ticket where it is (both are "open"); anything else lands
  # in the backlog, as an imported row does — Dolt knows nothing of promotion.
  #
  # The row is only touched when the Dolt status disagrees with the one the
  # ticket's current `state` projects to (or `closed_at` moved), so a re-run
  # is a no-op for tickets already in step.
  @status_sync_sql """
  UPDATE issues SET
    state = CASE
      WHEN $1 = 'closed' THEN 'closed'
      WHEN $1 = 'in_progress'
           AND ((pr_ref IS NOT NULL AND TRIM(pr_ref) != '')
                OR (pending_merge IS NOT NULL
                    AND TRIM(pending_merge) NOT IN ('', '{}', 'null')))
        THEN 'merging'
      WHEN $1 = 'in_progress' THEN 'active'
      WHEN state IN ('backlog', 'queued') THEN state
      ELSE 'backlog'
    END,
    close_reason = CASE WHEN $1 = 'closed' THEN COALESCE(close_reason, 'completed') END,
    closed_at = $2,
    updated_at = $3
  WHERE id = $4
    AND ((CASE state
            WHEN 'closed' THEN 'closed'
            WHEN 'active' THEN 'in_progress'
            WHEN 'merging' THEN 'in_progress'
            WHEN 'verifying' THEN 'awaiting_verification'
            ELSE 'open'
          END) != $1
         OR (closed_at IS DISTINCT FROM $2))
  """

  @doc """
  The `UPDATE` that refreshes an existing row's lifecycle `state` (and
  `closed_at`) from its Dolt row's status, as `{sql, params}`. bd-842qio:
  `close_reason` moves with the state, since this write goes around Ash.
  """
  def status_sync(row, now) do
    status = row["status"] |> map_status() |> Atom.to_string()
    closed_at = parse_dt(row["closed_at"])
    updated_at = parse_dt(row["updated_at"]) || now

    {@status_sync_sql, [status, closed_at, updated_at, row["id"]]}
  end

  @doc false
  def dependency_record(row, type, now) do
    %{
      # Dependency.id is Ash.Type.UUIDv7 — v7, and in string form (see above).
      id: Ash.UUIDv7.generate(),
      from_issue_id: row["issue_id"],
      to_issue_id: row["depends_on_id"],
      type: Atom.to_string(type),
      created_by: nonempty(row["created_by"]),
      notes: "",
      created_at: parse_dt(row["created_at"]) || now,
      updated_at: parse_dt(row["created_at"]) || now
    }
  end
end
