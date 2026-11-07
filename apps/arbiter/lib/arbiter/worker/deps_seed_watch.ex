defmodule Arbiter.Worker.DepsSeedWatch do
  @moduledoc """
  Makes a failing deps seed visible (bd-175f0r).

  `Arbiter.Worker.DepsCache` seeds are best-effort: a failed seed leaves the
  worker to fetch for itself. When the seed fails on every attempt (a repo's
  `config/runtime.exs` raising under the scrubbed seed env, say) that silently
  degrades every run, and in a cluster with no egress it leaves workers on an
  uncompilable checkout.

  `failed/4` counts consecutive failures per `{repo, image}`; at `threshold/0`
  it raises a `:deps_seed_failing` system alert naming the repo, image digest and
  the first line of the error. The per-spawn warning is logged once per
  `{image, first error line}`. `succeeded/2` clears the alert and the count.

  State lives in `:persistent_term` and is lost on restart, which at worst
  re-logs once.
  """

  require Logger

  alias Arbiter.Alerts

  @threshold 3
  @kind :deps_seed_failing

  @doc "Consecutive failures before an alert is raised."
  @spec threshold() :: pos_integer()
  def threshold, do: @threshold

  @doc """
  Record a failed seed of `repo` in `image`. Options: `:workspace_id`.
  Never raises: visibility must not break a spawn.
  """
  @spec failed(String.t() | nil, String.t(), term(), keyword()) :: :ok
  def failed(repo, image, reason, opts \\ []) do
    line = first_line(reason)
    log_once(repo, image, line)
    count = bump({:count, repo, image})
    if count >= @threshold, do: raise_alert(repo, image, line, count, opts)
    :ok
  rescue
    e ->
      Logger.debug("DepsSeedWatch: #{Exception.message(e)}")
      :ok
  end

  @doc "Record a successful seed: clears the alert and the failure count."
  @spec succeeded(String.t() | nil, String.t()) :: :ok
  def succeeded(repo, image) do
    :persistent_term.erase({__MODULE__, :count, repo, image})
    Alerts.clear(@kind, key(repo, image))
    :ok
  rescue
    _ -> :ok
  end

  @doc false
  def reset do
    for {{__MODULE__, _, _, _} = k, _} <- :persistent_term.get(), do: :persistent_term.erase(k)
    for {{__MODULE__, _, _} = k, _} <- :persistent_term.get(), do: :persistent_term.erase(k)
    :ok
  end

  @doc "The first line of a seed error, for the alert and the log."
  @spec first_line(term()) :: String.t()
  def first_line({:seed_failed, _status, out}) when is_binary(out), do: first_line(out)

  def first_line(text) when is_binary(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.find("(no output)", &(&1 != ""))
    |> String.slice(0, 300)
  end

  def first_line(other), do: other |> inspect(limit: 10) |> String.slice(0, 300)

  defp key(repo, image), do: "#{repo}|#{image}"

  defp bump(name) do
    k = {__MODULE__, elem(name, 0), elem(name, 1), elem(name, 2)}
    n = :persistent_term.get(k, 0) + 1
    :persistent_term.put(k, n)
    n
  end

  defp log_once(repo, image, line) do
    k = {__MODULE__, :logged, {image, line}}

    if :persistent_term.get(k, nil) == nil do
      :persistent_term.put(k, true)

      Logger.warning(
        "DepsCache: seed failed for #{repo || "(unknown repo)"} in #{image}: #{line} " <>
          "(further identical failures are not logged)"
      )
    end
  end

  defp raise_alert(repo, image, line, count, opts) do
    Alerts.raise_alert(%{
      kind: @kind,
      key: key(repo, image),
      workspace_id: Keyword.get(opts, :workspace_id),
      subject: "deps seed failing for #{repo || "(unknown repo)"}",
      detail:
        "The deps seed for repo #{repo || "(unknown)"} has failed #{count} times in a row " <>
          "in image #{image}. First error line: #{line}. Workers start without deps/_build " <>
          "(and cannot fetch them when the pod has no egress). Fix the seed " <>
          "(e.g. set worker.repos.<repo>.image.seed_env for keys config/runtime.exs needs).",
      owner: :coordinator
    })
  end
end
