defmodule Arbiter.Worker.ReviewMrBrief do
  @moduledoc """
  The reviewer's MR/PR evidence brief (#1146): the current MR/PR description and
  the head pipeline's status plus a bounded log tail of each failed job, fetched
  by Arbiter with its own forge token through the merge adapter's existing
  `get/1` and `failing_check_logs/1`. The reviewer needs no forge access, so a
  criterion backed by evidence in the description (a 50-run loop) or the
  pipeline is no longer failed for want of visibility.
  """

  alias Arbiter.Worker.ReviewCi

  @max_body 4_000
  @max_tail 1_500
  @max_jobs 8

  @doc "The standing instruction placed in every reviewer prompt."
  @spec instruction() :: String.t()
  def instruction do
    """
    EVIDENCE IN THE MR/PR AND CI: the diff is not the only evidence. Before you mark a
    criterion NOT MET, check the MR/PR description and the pipeline data in the
    brief (when one is shown) for evidence of it — a run loop, a benchmark, a
    pipeline result. You have no forge access; Arbiter fetched that data for you.
    """
  end

  @doc "The brief for `pr_ref` via `adapter`, or `\"\"` when there is no PR or the forge read failed."
  @spec fetch(term(), String.t() | nil, module() | nil, String.t() | nil) :: String.t()
  def fetch(_workspace, _repo, _adapter, pr_ref) when pr_ref in [nil, ""], do: ""
  def fetch(_workspace, _repo, nil, _pr_ref), do: ""

  def fetch(workspace, repo, adapter, pr_ref) do
    fun = fn ->
      mr = adapter.get(pr_ref)

      checks =
        if Code.ensure_loaded?(adapter) and function_exported?(adapter, :failing_check_logs, 1),
          do: adapter.failing_check_logs(pr_ref),
          else: {:ok, []}

      {mr, checks}
    end

    case ReviewCi.call(workspace, repo, fun) do
      {:ok, {{:ok, %{} = mr}, checks}} -> render(mr, ok_list(checks))
      _ -> ""
    end
  end

  @doc "Render an MR map (`:body`, `:pipeline`) and failed checks as a prompt block."
  @spec render(map(), [map()]) :: String.t()
  def render(mr, checks) do
    body = mr |> Map.get(:body) |> blank_to("(empty)") |> head(@max_body)

    jobs =
      case checks do
        [] ->
          "no failed jobs reported"

        _ ->
          checks
          |> Enum.take(@max_jobs)
          |> Enum.map_join("\n", fn c ->
            "- #{Map.get(c, :name)} [#{Map.get(c, :conclusion) || Map.get(c, :status) || "failed"}]\n" <>
              indent(tail(Map.get(c, :summary) || "", @max_tail))
          end)
      end

    """
    MR/PR description (current, fetched by Arbiter):
    #{body}

    Head pipeline (fetched by Arbiter):
    pipeline: #{Map.get(mr, :pipeline) || "unknown"}
    failed jobs: #{jobs}
    """
  end

  defp ok_list({:ok, list}) when is_list(list), do: list
  defp ok_list(_), do: []

  defp blank_to(v, d) when v in [nil, ""], do: d
  defp blank_to(v, _d) when is_binary(v), do: v
  defp blank_to(_v, d), do: d

  defp head(s, max) when byte_size(s) > max, do: binary_part(s, 0, max) <> "\n[...truncated]"
  defp head(s, _max), do: s

  defp tail(s, max) when byte_size(s) > max,
    do: "[...truncated]\n" <> binary_part(s, byte_size(s) - max, max)

  defp tail(s, _max), do: s

  defp indent(s), do: s |> String.split("\n") |> Enum.map_join("\n", &("    " <> &1))
end
