defmodule Arbiter.Worker.Dispatch.Params do
  @moduledoc """
  The one place a dispatch / resume / review request is turned into
  `Arbiter.Worker.Dispatch` opts. REST (`POST /api/workers/dispatch`,
  `/:task_id/resume`, `/review`) and MCP (`worker_dispatch`, `worker_resume`,
  `worker_review`) both call `normalize/2`; the CLI posts to REST, so it gets
  the same rules. Before bd-a9hqfb each surface had its own copy and they had
  drifted: MCP ignored `with_gemini` and unknown keys, REST skipped the
  recursion-depth guard and lost the quota-bypass attribution, the CLI let
  `--provider` beat `--no-agent`, and only some surfaces knew grok.

  ## Contract

  `normalize(params, opts)` takes the caller's string-keyed params and
  `verb:` (`:dispatch | :resume | :review`), `scope:` (the bearer token's
  `Arbiter.MCP.Scope`) and `surface:` (`:mcp | :rest`). It returns
  `{:ok, dispatch_opts}` or `{:error, {kind, message}}` with `kind` one of
  `:invalid` (a bad or unknown argument) or `:unauthorized` (the
  dispatch-recursion depth limit). It never raises and never starts anything.

    * **Unknown arguments are an error** — a typo is never silently dropped.
      `task_id` is accepted (the adapters read it); `workspace` is accepted over
      MCP only, where it narrows the task lookup.
    * **Booleans are strict** (`Arbiter.Params.boolean/1`); junk is `:invalid`.
    * **Provider** — `provider` must be one of `Arbiter.Agents.valid_agent_types/0`
      (grok included). `with_claude` / `with_gemini` are deprecated aliases and
      `no_agent` parks the ticket without spawning. They are mutually exclusive:
      `no_agent` with any provider selector, or two different providers, is
      refused instead of letting one silently win.
    * **Quota bypass** — `force_quota` sets `:skip_quota_gate` and stamps
      `:quota_bypass_actor` (the token's actor) and `:quota_bypass_reason` so the
      `quota_gate_bypass` event is attributed whichever surface sent it.
      `force_quota_reason` without `force_quota` is refused.
    * **Depth** — the scope must be under `Arbiter.MCP.max_depth/0`; the child
      worker's scope is minted at `depth + 1` (`:depth`).
    * **Resume** — `mode` is `session` (default: continue the prior session,
      `Dispatch.resume_session/2`) or `briefing` (a fresh agent briefed from the
      worktree's git state, `Dispatch.resume/2`). It comes back as `:resume_mode`;
      `Dispatch.resume_task/2` honours it.
  """

  alias Arbiter.Actor
  alias Arbiter.Agents

  @type verb :: :dispatch | :resume | :review

  @common ~w(task_id repo model force_quota force_quota_reason)
  @bool_keys [
    {"force", :force},
    {"over_cap", :over_cap},
    {"force_quota", :force_quota},
    {"no_agent", :no_agent},
    {"with_claude", :with_claude},
    {"with_gemini", :with_gemini}
  ]

  @verb_keys %{
    dispatch: ~w(provider with_claude with_gemini no_agent force over_cap),
    resume: ~w(force mode),
    # The review extras are read by the review-automation guard and the
    # external-PR path (`Arbiter.Reviews.Guard`, `ExternalReview`); they are
    # accepted here, not interpreted.
    review:
      ~w(with_claude force automation pr_author tracker_context_ref tracker_context_type) ++
        ~w(pr workspace follow_up scope report_only)
  }

  @spec normalize(map(), keyword()) ::
          {:ok, keyword()} | {:error, {:invalid | :unauthorized, String.t()}}
  def normalize(params, opts) when is_map(params) do
    verb = Keyword.fetch!(opts, :verb)
    scope = Keyword.fetch!(opts, :scope)
    surface = Keyword.get(opts, :surface, :rest)

    with :ok <- ensure_depth(scope),
         :ok <- ensure_known_keys(params, verb, surface),
         {:ok, flags} <- fetch_flags(params),
         {:ok, repo} <- fetch_string(params, "repo"),
         {:ok, model} <- fetch_string(params, "model"),
         {:ok, reason} <- fetch_string(params, "force_quota_reason"),
         :ok <- ensure_reason_has_force_quota(reason, flags.force_quota) do
      actor = actor_label(scope, surface)

      [depth: scope.depth + 1]
      |> put_present(:repo, repo)
      |> put_present(:model, model)
      |> put_quota_bypass(flags.force_quota, actor, reason)
      |> verb_opts(verb, params, flags, actor, surface)
    end
  end

  @doc "The dispatch-recursion guard: a scope at `Arbiter.MCP.max_depth/0` may not dispatch."
  @spec ensure_depth(Arbiter.MCP.Scope.t()) :: :ok | {:error, {:unauthorized, String.t()}}
  def ensure_depth(%{depth: depth}) do
    max = Arbiter.MCP.max_depth()

    if depth < max,
      do: :ok,
      else: {:error, {:unauthorized, "dispatch depth limit (#{max}) reached"}}
  end

  # ---- per verb ---------------------------------------------------------------

  defp verb_opts(base, :dispatch, params, flags, actor, surface) do
    with {:ok, selection} <- select_agent(params, flags) do
      opts =
        base
        # bd-asxw4e: dispatch a Backlog or Blocked ticket anyway (recorded).
        |> Keyword.put(:force, flags.force)
        # bd-8suxac: go over a full provider account's cap (recorded).
        |> Keyword.put(:force_slot, flags.over_cap)
        |> Keyword.put(:slot_override_actor, actor)
        |> Keyword.put(:dispatched_by, dispatched_by(surface))

      {:ok, apply_selection(opts, selection)}
    end
  end

  defp verb_opts(base, :resume, params, flags, actor, _surface) do
    with {:ok, mode} <- resume_mode(params) do
      {:ok,
       base
       |> Keyword.put(:resume_origin, :human)
       |> Keyword.put(:force_slot, flags.force)
       |> Keyword.put(:slot_override_actor, actor)
       |> Keyword.put(:resume_mode, mode)}
    end
  end

  # `worker_review` is claude-driven: a reviewer with no agent has nothing to do.
  # `with_claude: false` dispatches the review without spawning one (the test
  # affordance); the Driver is suppressed only then, since for a real review it
  # is the sole component that closes the task on :completed.
  defp verb_opts(base, :review, _params, flags, _actor, _surface) do
    claude? = flags.with_claude != false

    opts = base |> Keyword.put(:review, true) |> Keyword.put(:start_claude, claude?)
    {:ok, if(claude?, do: opts, else: Keyword.put(opts, :start_driver, false))}
  end

  defp resume_mode(params) do
    case Map.get(params, "mode") do
      nil ->
        {:ok, :session}

      "session" ->
        {:ok, :session}

      "briefing" ->
        {:ok, :briefing}

      other ->
        {:error, {:invalid, "`mode` must be \"session\" or \"briefing\", got #{inspect(other)}"}}
    end
  end

  # ---- agent selection (dispatch) ----------------------------------------------

  # `{:park}` | `{:default}` | `{:agent, atom}` | `{:error, ...}`.
  defp select_agent(params, flags) do
    with {:ok, provider} <- explicit_provider(params) do
      named =
        [
          provider,
          if(flags.with_claude, do: :claude),
          if(flags.with_gemini, do: :gemini)
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      cond do
        flags.no_agent and named != [] ->
          {:error,
           {:invalid,
            "`no_agent` parks the ticket without a worker and cannot be combined with " <>
              "`provider`, `with_claude` or `with_gemini`"}}

        flags.no_agent ->
          {:ok, :park}

        match?([_, _ | _], named) ->
          {:error,
           {:invalid,
            "conflicting provider selection (#{Enum.join(named, ", ")}); " <>
              "pass one `provider`, and drop the deprecated `with_claude` / `with_gemini`"}}

        named == [] ->
          {:ok, :default}

        true ->
          {:ok, {:agent, hd(named)}}
      end
    end
  end

  defp explicit_provider(params) do
    case Map.get(params, "provider") do
      nil ->
        {:ok, nil}

      p when is_binary(p) ->
        trimmed = String.trim(p)

        cond do
          trimmed == "" ->
            {:ok, nil}

          trimmed in Agents.valid_agent_types() ->
            {:ok, String.to_existing_atom(trimmed)}

          true ->
            {:error, {:invalid, unknown_provider_message(p)}}
        end

      other ->
        {:error, {:invalid, unknown_provider_message(other)}}
    end
  end

  defp unknown_provider_message(value) do
    "unknown provider #{inspect(value)}; valid providers: " <>
      Enum.join(Agents.valid_agent_types(), ", ")
  end

  defp apply_selection(opts, :park), do: Keyword.put(opts, :start_driver, false)
  defp apply_selection(opts, :default), do: Keyword.put(opts, :start_claude, true)

  defp apply_selection(opts, {:agent, type}),
    do: opts |> Keyword.put(:start_claude, true) |> Keyword.put(:agent_type, type)

  # ---- shared pieces ----------------------------------------------------------

  @doc "The argument names `verb` accepts from `surface` (`:rest` or `:mcp`)."
  @spec accepted_keys(verb(), :rest | :mcp) :: [String.t()]
  def accepted_keys(verb, surface),
    do:
      @common ++ Map.fetch!(@verb_keys, verb) ++ if(surface == :mcp, do: ["workspace"], else: [])

  defp ensure_known_keys(params, verb, surface) do
    allowed = accepted_keys(verb, surface)

    case params |> Map.keys() |> Enum.map(&to_string/1) |> Enum.reject(&(&1 in allowed)) do
      [] ->
        :ok

      unknown ->
        {:error,
         {:invalid,
          "unknown argument(s) for #{verb}: #{Enum.join(Enum.sort(unknown), ", ")}; " <>
            "accepted: #{Enum.join(Enum.sort(allowed), ", ")}"}}
    end
  end

  defp fetch_flags(params) do
    Enum.reduce_while(@bool_keys, {:ok, %{}}, fn {key, name}, {:ok, acc} ->
      case Arbiter.Params.fetch_optional_bool(params, key) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, name, flag_value(name, value))}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  # `with_claude` keeps its tri-state (a review treats an explicit `false` as
  # "no agent"); every other flag is a plain boolean.
  defp flag_value(:with_claude, value), do: value
  defp flag_value(_key, value), do: value == true

  defp fetch_string(params, key) do
    case Map.get(params, key) do
      nil ->
        {:ok, nil}

      v when is_binary(v) ->
        case String.trim(v) do
          "" -> {:ok, nil}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, {:invalid, "`#{key}` must be a string"}}
    end
  end

  defp ensure_reason_has_force_quota(nil, _force_quota), do: :ok
  defp ensure_reason_has_force_quota(_reason, true), do: :ok

  defp ensure_reason_has_force_quota(_reason, false),
    do: {:error, {:invalid, "`force_quota_reason` requires `force_quota: true`"}}

  defp put_quota_bypass(opts, false, _actor, _reason), do: opts

  defp put_quota_bypass(opts, true, actor, reason) do
    opts
    |> Keyword.put(:skip_quota_gate, true)
    |> Keyword.put(:quota_bypass_actor, actor)
    |> put_present(:quota_bypass_reason, reason)
  end

  defp put_present(opts, _key, nil), do: opts
  defp put_present(opts, key, value), do: Keyword.put(opts, key, value)

  # Attribution comes from the bearer token, never from the caller.
  defp actor_label(scope, surface) do
    case Actor.from_scope(scope) do
      nil -> if(surface == :mcp, do: "coordinator", else: "api")
      actor -> Actor.label(actor)
    end
  end

  defp dispatched_by(:mcp), do: "mcp"
  defp dispatched_by(:rest), do: "http_api"
end
