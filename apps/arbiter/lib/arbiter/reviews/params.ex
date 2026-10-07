defmodule Arbiter.Reviews.Params do
  @moduledoc """
  The one place an external-review request's arguments are coerced into
  `Arbiter.Reviews.ExternalReview` options (parity audit P-12, D-W-6).

  MCP (`worker_review pr:`, `review_greenlight`), REST
  (`POST /api/workers/review`, `POST /api/external_reviews/:id/greenlight`) and
  therefore the CLI all hand their string-keyed argument map here, so a flag
  `ExternalReview.describe_error/1` tells a caller to pass (`force`, ...) is
  accepted by every surface and means the same thing on each.

  Errors are `{:error, {:invalid, message}}`; REST maps them with
  `Arbiter.Params.to_rest/1`.
  """

  alias Arbiter.Params

  @type error :: {:error, {:invalid, String.t()}}

  @doc """
  `ExternalReview.dispatch/1` options from a request's arguments.

  `base` is what the surface decides itself (`workspace:`, `dispatched_by:`);
  everything else comes from `args`: `pr`, `repo`, `automation`, `follow_up`,
  `force`, `report_only`, `scope`, `tracker_context_ref`, `tracker_context_type`.
  Unset flags are left out so `ExternalReview` applies its own defaults.
  """
  @spec dispatch_opts(map(), keyword()) :: {:ok, keyword()} | error()
  def dispatch_opts(args, base) when is_map(args) do
    with {:ok, follow_up} <- Params.fetch_optional_bool(args, "follow_up"),
         {:ok, force} <- Params.fetch_optional_bool(args, "force"),
         {:ok, report_only} <- Params.fetch_optional_bool(args, "report_only") do
      opts =
        base
        |> Keyword.merge(
          pr: string(args, "pr"),
          repo: string(args, "repo"),
          automation: string(args, "automation"),
          tracker_context_ref: string(args, "tracker_context_ref"),
          tracker_context_type: string(args, "tracker_context_type")
        )
        |> put_present(:follow_up, follow_up)
        |> put_present(:force, force)
        |> put_present(:report_only, if(report_only, do: true))
        |> put_present(:scope, string(args, "scope"))

      {:ok, opts}
    end
  end

  @doc """
  `ExternalReview.greenlight/1` options from a request's arguments:
  `record_id` (the caller supplies it — a path segment on REST), `repo`,
  `select` and `post_verdict`.
  """
  @spec greenlight_opts(String.t(), map()) :: {:ok, keyword()} | error()
  def greenlight_opts(record_id, args) when is_binary(record_id) and is_map(args) do
    with {:ok, select} <- select(args),
         {:ok, post_verdict} <- Params.fetch_optional_bool(args, "post_verdict") do
      opts =
        [record_id: record_id, repo: string(args, "repo")]
        |> put_present(:select, select)
        |> put_present(:post_verdict, post_verdict)

      {:ok, opts}
    end
  end

  # `select` may be omitted (→ nil, meaning all), the string "all", or a list of
  # zero-based indices (`[]` approves nothing). Anything else is rejected.
  defp select(args) do
    case Map.get(args, "select") do
      nil ->
        {:ok, nil}

      "all" ->
        {:ok, :all}

      list when is_list(list) ->
        if Enum.all?(list, &(is_integer(&1) and &1 >= 0)),
          do: {:ok, list},
          else: {:error, {:invalid, select_message()}}

      _ ->
        {:error, {:invalid, select_message()}}
    end
  end

  defp select_message, do: "select must be \"all\" or a list of non-negative integers"

  defp string(args, key) do
    case Map.get(args, key) do
      s when is_binary(s) ->
        case String.trim(s) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp put_present(kw, _key, nil), do: kw
  defp put_present(kw, key, value), do: Keyword.put(kw, key, value)
end
