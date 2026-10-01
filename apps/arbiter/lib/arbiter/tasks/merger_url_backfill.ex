defmodule Arbiter.Tasks.MergerUrlBackfill do
  @moduledoc """
  One-shot, idempotent repair of GitLab MR links stored with the numeric
  project id (`https://gitlab.com/68258632/-/merge_requests/298`, a 404)
  instead of the namespace path
  (`https://gitlab.com/<group>/<project>/-/merge_requests/298`).

  `Arbiter.Mergers.Gitlab.link_for/1` used to fall back to the bare project id
  when the path lookup failed, and the result was persisted onto
  `issues.merger_url`. For each issue whose `merger_url` matches
  `https://<host>/<digits>/-/merge_requests/<iid>`, the link is rebuilt through
  `Arbiter.Mergers.link_for_workspace/3` (so the task's repo's own project id is
  used) and rewritten. Rows whose path still cannot be resolved are left alone
  and reported, so the run can be repeated.

  Only rows matching the numeric shape are ever selected, so a second run has
  nothing to do once every row is repaired.
  """

  require Ash.Query

  alias Arbiter.Mergers
  alias Arbiter.Tasks.Issue

  @numeric_url ~r{^(https?://[^/]+)/\d+/-/merge_requests/(\d+)/?$}

  @type entry :: %{
          issue_id: String.t(),
          old_url: String.t(),
          new_url: String.t() | nil
        }

  @doc "Every issue with a numeric-id MR link and the link it would get. Pure read."
  @spec plan() :: [entry()]
  def plan do
    # Matched in Elixir: SQLite `contains/2` on this column returned nothing
    # for a "/-/merge_requests/" needle. Only the two columns are read.
    ids =
      Issue
      |> Ash.Query.filter(not is_nil(merger_url))
      |> Ash.Query.select([:id, :merger_url])
      |> Ash.read!()
      |> Enum.filter(&numeric_url?(&1.merger_url))
      |> Enum.map(& &1.id)

    Issue
    |> Ash.Query.filter(id in ^ids)
    |> Ash.Query.load(:workspace)
    |> Ash.read!()
    |> Enum.sort_by(& &1.id)
    |> Enum.map(&plan_issue/1)
  end

  @doc "Apply a `plan/0`. Returns `{updated_ids, errors}`; unresolved entries are skipped."
  @spec apply!([entry()]) :: {[String.t()], [{String.t(), String.t()}]}
  def apply!(plan) when is_list(plan) do
    {ok, errors} =
      plan
      |> Enum.filter(& &1.new_url)
      |> Enum.reduce({[], []}, fn entry, {ok, errors} ->
        case write(entry) do
          :ok -> {[entry.issue_id | ok], errors}
          {:error, msg} -> {ok, [{entry.issue_id, msg} | errors]}
        end
      end)

    {Enum.reverse(ok), Enum.reverse(errors)}
  end

  @doc "True for `https://<host>/<digits>/-/merge_requests/<iid>`."
  def numeric_url?(url) when is_binary(url), do: Regex.match?(@numeric_url, url)
  def numeric_url?(_), do: false

  defp plan_issue(issue) do
    [_, _host, iid] = Regex.run(@numeric_url, issue.merger_url)
    url = Mergers.link_for_workspace(issue.workspace, "!" <> iid, issue.repo)

    new_url = if url == "" or numeric_url?(url), do: nil, else: url

    %{issue_id: issue.id, old_url: issue.merger_url, new_url: new_url}
  rescue
    _ -> %{issue_id: issue.id, old_url: issue.merger_url, new_url: nil}
  end

  defp write(%{issue_id: id, new_url: url}) do
    with {:ok, issue} <- Ash.get(Issue, id),
         {:ok, _} <-
           issue
           |> Ash.Changeset.for_update(:record_pr, %{merger_url: url})
           |> Ash.update() do
      :ok
    else
      {:error, error} -> {:error, Exception.message(error)}
    end
  end
end
