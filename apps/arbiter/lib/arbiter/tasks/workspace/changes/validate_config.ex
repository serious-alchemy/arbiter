defmodule Arbiter.Tasks.Workspace.Changes.ValidateConfig do
  @moduledoc """
  Validates the shape of a `Workspace.config` JSON map on create/update.

  Rules (loose — most keys are optional):

    * Top-level must be a map (or `nil` / missing — treated as `%{}`).
    * If `"tracker"` is present, it must be a map.
    * If `"tracker.type"` is present, it must be one of the values in
      `Arbiter.Tasks.Workspace.valid_tracker_types/0` (`"none"`, `"jira"`,
      `"shortcut"`, `"linear"`, `"github"`, `"gitlab"`).
    * If `"tracker.child_policy"` is present, it must be one of the values in
      `Arbiter.Tasks.Workspace.valid_tracker_child_policies/0` (`"context_only"`,
      `"inherit_parent"`, `"mint"`) — a typo would otherwise read as the
      `context_only` default without a word (#1973).
    * If `"tracker.config"` is present, it must be a map.
    * If `"merge"` is present, it must be a map. Its optional `"repos"` is a
      map of per-repo override maps (bd-73zv62), each validated like `"merge"`.
    * If `"merge.strategy"` is present, it must be one of the values in
      `Arbiter.Tasks.Workspace.valid_merger_strategies/0` (`"direct"`, `"gitlab"`, `"github"`).
    * If `"agent"` / `"review_agent"` is present, it must be a map.
    * If `"agent.type"` is present, it must be one of the values in
      `Arbiter.Agents.valid_agent_types/0` (`"claude"`, `"gemini"`, `"codex"`),
      OR a non-empty list of such strings (multi-provider pool).
    * If `"agent.config"` / `"review_agent.config"` is present, it must be a map.
    * If `"review_agent.cross_family"` is present, it must be a boolean
      (bd-a1ke2c).
    * If `"guardrails"` is present it must pass
      `Arbiter.Guardrails.Config.validate/1` (bd-anwb0u, G11).
    * If `"agent.security.sandbox.egress"` (or a per-repo
      `"agent.security.repos.<repo>.sandbox.egress"`) is present, it must be one
      of `Arbiter.Agents.SecurityPolicy.valid_egress_levels/0` (`"open"`,
      `"allowlist"`, `"none"`); a typo would otherwise read as the inherited
      level without a word (bd-5yydxh). Its `"allow_hosts"` must be a list of
      `host:port` entries the egress proxy accepts as a baseline.
    * If `"agent.security.sandbox.backend"` (or a per-repo override) is present,
      it must be one of `Arbiter.Agents.SecurityPolicy.valid_sandbox_backends/0`
      (`"bwrap"`, `"podman"`) (bd-btcdrf). `"review_backend"` takes the same
      values (bd-4rvf98); `"podman"` there is accepted but refuses every review
      spawn, so it parks them rather than run unjailed.
    * If `"routing"` is present, it must be a map.
    * If `"routing.policy"` is present, it must be one of the values in
      `Arbiter.Agents.Routing.valid_policies/0` (`"static"`, `"by_priority"`,
      `"by_difficulty"`, `"by_budget"`, `"round_robin"`).
    * If `"routing.provider_selection"` is present, it must be one of
      `Arbiter.Agents.ProviderRouting.valid_selections/0` (`"failover"`,
      `"most_quota"`, `"scored"`).
    * If `"routing.scoring"` is present (bd-adtnto), it must be a map whose
      `"mode"` is `"shadow"` or `"enforce"` and whose `"time_weight"` maps
      `"P0"`..`"P4"` to non-negative numbers.
    * If `"routing.capability_gates"` is present, it must be a boolean
      (bd-57uzkl); a per-repo `"routing.repos.<repo>.requires"` must be a list
      of `Arbiter.Agents.CapabilityMatrix.capabilities/0`.
    * If `"routing.floors"` is present it must be a map (bd-c675ny):
      `"policy_floor"` a boolean, and each `"repos.<repo>.min_model_tier"` one
      of `Arbiter.Agents.Floors.ladder/0` — a typo'd tier would otherwise read
      as no floor at all.
    * If `"review.require_ci_green"` (or a per-repo
      `"review.repos.<repo>.require_ci_green"`) is present, it must be a boolean
      or `"true"` / `"false"` (bd-cut6uv).
    * If `"review_gate"` is present, it must be a map.
    * If `"review_gate.max_rounds"` is present, it must be a positive integer.
    * If `"review_gate.timeout_ms"` is present, it must be a positive integer.
    * If `"review_gate.max_fix_rounds"` is present, it must be a NON-NEGATIVE
      integer — `0` is the documented switch that disables the auto fix round
      (bd-a9zb7w), so it cannot share the positive-integer validator.
    * If `"notes_gate"` is present, it must be a map; if
      `"notes_gate.nudge_cap"` is present it must be a NON-NEGATIVE integer —
      `0` escalates on the first blank-notes completion (bd-4qjl0q).
    * If `"conductor"` is present, it must be a map.
    * If `"conductor.max_concurrent"` is present, it must be a positive integer.
    * If `"review_automation"` is present, it must be a map.
    * If `"review_automation.default"` is present, it must be one of
      `"auto"`, `"report_only"` (alias `"propose"`), or `"flag"` (alias `"notify"`).
    * If `"review_automation.auto_authors"` is present, it must be a list of strings.
    * If `"review_automation.repo_overrides"` is present, it must be a map where
      every value is one of the modes above.
    * If `"loop"` is present, it must be a map; if `"loop.evidence_bar"` is
      present, it must be a map whose `"min_incidents"` / `"min_distinct_tasks"`
      are positive integers (the loop-proposal evidence bar, bd-9j2g3x); if
      `"loop.ci"` is present it must be a map whose `"lint_share_threshold"` is
      a number in (0, 1], `"min_fix_passes"` a positive integer,
      `"check_commands"` a map of repo name → command string (bd-cuu8n3), and
      `"flake_recurrence_threshold"` a positive integer (bd-6vullc).
    * If `"worker"` is present, it must be a map. Its `"seed_paths"` (and each
      per-repo `"worker.repos.<repo>.seed_paths"`) must be a list of strings
      (bd-2jerqw, `Arbiter.Worker.SeedPaths`). The entries themselves are
      checked when a worktree is seeded: an absolute, `..` or `.git` entry is
      skipped with a logged warning rather than refused here. The same blocks
      may carry `"prepush_check"` (a non-empty command string),
      `"prepush_check_timeout_seconds"` (a positive integer) and
      `"prepush_check_on_timeout"` (`"proceed"` or `"fail"`) — bd-28c6qo,
      `Arbiter.Worker.PrepushCheck`.
    * If `"attention"` is present, it must be a map whose
      `"coordinator_limit_minutes"` / `"run_crashed_max_resumes"` are
      non-negative integers — `0` turns a limit off (bd-8nlez1,
      `Arbiter.Tasks.AttentionLimits`).

  Unknown keys are allowed (forward-compat) — including any legacy
  `"vernacular"` key, which is now ignored rather than validated.
  """

  use Ash.Resource.Change

  alias Arbiter.Worker.Egress.Policy, as: EgressPolicy
  alias Ash.Changeset

  @impl true
  def change(changeset, _opts, _context) do
    case Changeset.get_attribute(changeset, :config) do
      nil -> changeset
      config when is_map(config) -> changeset |> validate(config) |> apply_policy()
      _other -> Changeset.add_error(changeset, field: :config, message: "must be a map")
    end
  end

  # Seam #10: cross-workspace policy hook; skipped once shape validation failed.
  defp apply_policy(%Changeset{valid?: false} = changeset), do: changeset

  defp apply_policy(changeset) do
    policy =
      Application.get_env(
        :arbiter,
        :workspace_config_policy,
        Arbiter.Tasks.Workspace.ConfigPolicy.Default
      )

    config = Changeset.get_attribute(changeset, :config)

    context = %{
      action: changeset.action && changeset.action.type,
      workspace: if(changeset.data.__meta__.state == :loaded, do: changeset.data)
    }

    case policy.check(config, context) do
      :ok -> changeset
      {:ok, new} when is_map(new) -> Changeset.force_change_attribute(changeset, :config, new)
      {:error, message} -> Changeset.add_error(changeset, field: :config, message: message)
    end
  end

  defp validate(changeset, config) do
    changeset
    |> validate_tracker(Map.get(config, "tracker"))
    |> validate_merge(Map.get(config, "merge"))
    |> validate_agent_block("agent", Map.get(config, "agent"))
    |> validate_agent_security(Map.get(config, "agent"))
    |> validate_guardrails(Map.get(config, "guardrails"))
    |> validate_agent_block("review_agent", Map.get(config, "review_agent"))
    |> validate_cross_family(Map.get(config, "review_agent"))
    |> validate_routing(Map.get(config, "routing"))
    |> validate_review_gate(Map.get(config, "review_gate"))
    |> validate_review(Map.get(config, "review"))
    |> validate_notes_gate(Map.get(config, "notes_gate"))
    |> validate_conductor(Map.get(config, "conductor"))
    |> validate_review_automation(Map.get(config, "review_automation"))
    |> validate_quota(Map.get(config, "quota"))
    |> validate_loop(Map.get(config, "loop"))
    |> validate_attention(Map.get(config, "attention"))
    |> validate_worker(Map.get(config, "worker"))
  end

  # bd-2jerqw: `worker.seed_paths` / `worker.repos.<repo>.seed_paths`.
  defp validate_worker(changeset, nil), do: changeset

  defp validate_worker(changeset, worker) when is_map(worker) do
    changeset
    |> validate_worker_block(worker, "worker")
    |> validate_worker_repos(Map.get(worker, "repos"))
  end

  defp validate_worker(changeset, _) do
    Changeset.add_error(changeset, field: :config, message: "worker must be a map")
  end

  defp validate_worker_repos(changeset, nil), do: changeset

  defp validate_worker_repos(changeset, repos) when is_map(repos) do
    Enum.reduce(repos, changeset, fn
      {repo, %{} = block}, cs ->
        validate_worker_block(cs, block, "worker.repos.#{repo}")

      {repo, _}, cs ->
        Changeset.add_error(cs,
          field: :config,
          message: "worker.repos.#{repo} must be a map"
        )
    end)
  end

  defp validate_worker_repos(changeset, _) do
    Changeset.add_error(changeset, field: :config, message: "worker.repos must be a map")
  end

  defp validate_worker_block(changeset, block, label) do
    changeset
    |> validate_seed_paths(block, label)
    |> validate_prepush_check(block, label)
  end

  # bd-28c6qo: `prepush_check` (+ `_timeout_seconds`, `_on_timeout`), at either
  # level (`Arbiter.Worker.PrepushCheck`).
  defp validate_prepush_check(changeset, block, label) do
    changeset
    |> validate_prepush_command(Map.get(block, "prepush_check"), label)
    |> validate_prepush_timeout(Map.get(block, "prepush_check_timeout_seconds"), label)
    |> validate_prepush_on_timeout(Map.get(block, "prepush_check_on_timeout"), label)
  end

  defp validate_prepush_command(changeset, nil, _label), do: changeset

  defp validate_prepush_command(changeset, command, label) do
    if is_binary(command) and String.trim(command) != "",
      do: changeset,
      else: prepush_error(changeset, "#{label}.prepush_check must be a non-empty string")
  end

  defp validate_prepush_timeout(changeset, nil, _label), do: changeset

  defp validate_prepush_timeout(changeset, n, _label) when is_integer(n) and n > 0, do: changeset

  defp validate_prepush_timeout(changeset, _, label),
    do:
      prepush_error(
        changeset,
        "#{label}.prepush_check_timeout_seconds must be a positive integer"
      )

  defp validate_prepush_on_timeout(changeset, nil, _label), do: changeset

  defp validate_prepush_on_timeout(changeset, v, _label) when v in ["proceed", "fail"],
    do: changeset

  defp validate_prepush_on_timeout(changeset, _, label),
    do:
      prepush_error(
        changeset,
        ~s(#{label}.prepush_check_on_timeout must be "proceed" or "fail")
      )

  defp prepush_error(changeset, message),
    do: Changeset.add_error(changeset, field: :config, message: message)

  defp validate_seed_paths(changeset, block, label) do
    case Map.get(block, "seed_paths") do
      nil ->
        changeset

      paths when is_list(paths) ->
        if Enum.all?(paths, &is_binary/1),
          do: changeset,
          else: seed_paths_error(changeset, label)

      _ ->
        seed_paths_error(changeset, label)
    end
  end

  defp seed_paths_error(changeset, label) do
    Changeset.add_error(changeset,
      field: :config,
      message: "#{label}.seed_paths must be a list of strings"
    )
  end

  # bd-anwb0u (G11): the `guardrails` block — bindings, ticket defaults and
  # per-subject caps (`Arbiter.Guardrails.Config`). Unknown keys are refused: a
  # typo in a security block must not read as "configured".
  defp validate_guardrails(changeset, nil), do: changeset

  defp validate_guardrails(changeset, block) do
    block
    |> Arbiter.Guardrails.Config.validate()
    |> Enum.reduce(changeset, fn message, cs ->
      Changeset.add_error(cs, field: :config, message: message)
    end)
  end

  # bd-8nlez1: the escalation limits (`Arbiter.Tasks.AttentionLimits`). Zero is
  # meaningful — it turns a limit off.
  defp validate_attention(changeset, nil), do: changeset

  defp validate_attention(changeset, attention) when is_map(attention) do
    changeset
    |> validate_non_negative_int(
      attention,
      "coordinator_limit_minutes",
      "attention.coordinator_limit_minutes"
    )
    |> validate_non_negative_int(
      attention,
      "run_crashed_max_resumes",
      "attention.run_crashed_max_resumes"
    )
  end

  defp validate_attention(changeset, _) do
    Changeset.add_error(changeset, field: :config, message: "attention must be a map")
  end

  defp validate_tracker(changeset, nil), do: changeset

  defp validate_tracker(changeset, tracker) when is_map(tracker) do
    valid_types = Arbiter.Tasks.Workspace.valid_tracker_types()

    changeset
    |> then(fn cs ->
      case Map.get(tracker, "type") do
        nil ->
          cs

        type ->
          if type in valid_types do
            cs
          else
            Changeset.add_error(cs,
              field: :config,
              message:
                "tracker.type must be one of #{Enum.join(valid_types, ", ")}; got: #{inspect(type)}"
            )
          end
      end
    end)
    |> validate_child_policy(Map.get(tracker, "child_policy"))
    |> then(fn cs ->
      case Map.get(tracker, "config") do
        nil -> cs
        c when is_map(c) -> cs
        _ -> Changeset.add_error(cs, field: :config, message: "tracker.config must be a map")
      end
    end)
  end

  defp validate_tracker(changeset, _) do
    Changeset.add_error(changeset, field: :config, message: "tracker must be a map")
  end

  defp validate_child_policy(changeset, nil), do: changeset

  defp validate_child_policy(changeset, policy) do
    valid = Arbiter.Tasks.Workspace.valid_tracker_child_policies()

    if policy in valid do
      changeset
    else
      Changeset.add_error(changeset,
        field: :config,
        message:
          "tracker.child_policy must be one of #{Enum.join(valid, ", ")}; got: #{inspect(policy)}"
      )
    end
  end

  defp validate_merge(changeset, nil), do: changeset

  defp validate_merge(changeset, merge) when is_map(merge) do
    changeset
    |> validate_merge_fields(merge, "merge")
    |> validate_merge_repos(Map.get(merge, "repos"))
  end

  defp validate_merge(changeset, _) do
    Changeset.add_error(changeset, field: :config, message: "merge must be a map")
  end

  # bd-73zv62: `merge.repos.<repo>` — a per-repo override of the merge block,
  # deep-merged over it (`Arbiter.Mergers.merge_config/2`). Each entry takes
  # the same fields, validated the same way; it cannot nest another `repos`.
  defp validate_merge_repos(changeset, nil), do: changeset

  defp validate_merge_repos(changeset, repos) when is_map(repos) do
    Enum.reduce(repos, changeset, fn
      {key, %{"repos" => _}}, cs ->
        Changeset.add_error(cs,
          field: :config,
          message: "merge.repos.#{key} cannot nest its own repos block"
        )

      {key, entry}, cs when is_map(entry) ->
        validate_merge_fields(cs, entry, "merge.repos.#{key}")

      {key, _entry}, cs ->
        Changeset.add_error(cs, field: :config, message: "merge.repos.#{key} must be a map")
    end)
  end

  defp validate_merge_repos(changeset, _) do
    Changeset.add_error(changeset, field: :config, message: "merge.repos must be a map")
  end

  # Pre-existing complexity 12 — baselined when bd-4x2yhq first
  # wired Credo up. Thresholds stay at the tool's own default so new
  # code is held to it; see the note in .credo.exs.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp validate_merge_fields(changeset, merge, label) do
    valid_strategies = Arbiter.Tasks.Workspace.valid_merger_strategies()

    changeset
    |> then(fn cs ->
      case Map.get(merge, "strategy") do
        nil ->
          cs

        strategy ->
          if strategy in valid_strategies do
            cs
          else
            Changeset.add_error(cs,
              field: :config,
              message:
                "#{label}.strategy must be one of #{Enum.join(valid_strategies, ", ")}; got: #{inspect(strategy)}"
            )
          end
      end
    end)
    |> then(fn cs ->
      case Map.get(merge, "watchdog_max_polls") do
        nil ->
          cs

        n when is_integer(n) and n > 0 ->
          cs

        "infinity" ->
          cs

        s when is_binary(s) ->
          case Integer.parse(s) do
            {n, ""} when n > 0 ->
              cs

            _ ->
              Changeset.add_error(cs,
                field: :config,
                message:
                  "#{label}.watchdog_max_polls must be a positive integer or \"infinity\"; got: #{inspect(s)}"
              )
          end

        other ->
          Changeset.add_error(cs,
            field: :config,
            message:
              "#{label}.watchdog_max_polls must be a positive integer or \"infinity\"; got: #{inspect(other)}"
          )
      end
    end)
  end

  defp validate_agent_block(changeset, _label, nil), do: changeset

  # Pre-existing complexity 12 — baselined when bd-4x2yhq first
  # wired Credo up. Thresholds stay at the tool's own default so new
  # code is held to it; see the note in .credo.exs.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp validate_agent_block(changeset, label, block) when is_map(block) do
    valid_types = Arbiter.Agents.valid_agent_types()

    changeset
    |> then(fn cs ->
      case Map.get(block, "type") do
        nil ->
          cs

        type when is_binary(type) ->
          if type in valid_types do
            cs
          else
            Changeset.add_error(cs,
              field: :config,
              message:
                "#{label}.type must be one of #{Enum.join(valid_types, ", ")}; got: #{inspect(type)}"
            )
          end

        types when is_list(types) ->
          invalid = Enum.reject(types, &(&1 in valid_types))

          cond do
            types == [] ->
              Changeset.add_error(cs,
                field: :config,
                message: "#{label}.type list must not be empty"
              )

            invalid != [] ->
              Changeset.add_error(cs,
                field: :config,
                message:
                  "#{label}.type list contains invalid types #{inspect(invalid)}; " <>
                    "each must be one of #{Enum.join(valid_types, ", ")}"
              )

            true ->
              cs
          end

        other ->
          Changeset.add_error(cs,
            field: :config,
            message: "#{label}.type must be a string or list of strings; got: #{inspect(other)}"
          )
      end
    end)
    |> then(fn cs ->
      case Map.get(block, "config") do
        nil -> cs
        c when is_map(c) -> cs
        _ -> Changeset.add_error(cs, field: :config, message: "#{label}.config must be a map")
      end
    end)
  end

  defp validate_agent_block(changeset, label, _) do
    Changeset.add_error(changeset, field: :config, message: "#{label} must be a map")
  end

  # bd-5yydxh: `agent.security.sandbox.{egress,allow_hosts,backend}`, workspace-wide
  # and under `agent.security.repos.<repo>`. Only these keys are checked;
  # the rest of the security block stays lenient (SecurityPolicy ignores what
  # it does not understand).
  defp validate_agent_security(changeset, %{"security" => %{} = security}) do
    repos =
      case Map.get(security, "repos") do
        %{} = repos -> repos
        _ -> %{}
      end

    repos
    |> Enum.filter(fn {_repo, override} -> is_map(override) end)
    |> Enum.reduce(
      validate_sandbox_egress(changeset, security, "agent.security"),
      fn {repo, override}, cs ->
        validate_sandbox_egress(cs, override, "agent.security.repos.#{repo}")
      end
    )
  end

  defp validate_agent_security(changeset, _agent), do: changeset

  defp validate_sandbox_egress(changeset, %{"sandbox" => %{} = sandbox}, label) do
    changeset
    |> validate_egress_level(Map.get(sandbox, "egress"), label)
    |> validate_allow_hosts(Map.get(sandbox, "allow_hosts"), label)
    |> validate_sandbox_backend(Map.get(sandbox, "backend"), "backend", label)
    |> validate_sandbox_backend(Map.get(sandbox, "review_backend"), "review_backend", label)
  end

  defp validate_sandbox_egress(changeset, _block, _label), do: changeset

  defp validate_egress_level(changeset, nil, _label), do: changeset

  defp validate_egress_level(changeset, level, label) do
    valid = Arbiter.Agents.SecurityPolicy.valid_egress_levels()

    if is_binary(level) and level in Enum.map(valid, &Atom.to_string/1) do
      changeset
    else
      Changeset.add_error(changeset,
        field: :config,
        message:
          "#{label}.sandbox.egress must be one of #{Enum.map_join(valid, ", ", &Atom.to_string/1)}; " <>
            "got: #{inspect(level)}"
      )
    end
  end

  defp validate_sandbox_backend(changeset, nil, _key, _label), do: changeset

  defp validate_sandbox_backend(changeset, backend, key, label) do
    valid = Arbiter.Agents.SecurityPolicy.valid_sandbox_backends()

    if is_binary(backend) and backend in Enum.map(valid, &Atom.to_string/1) do
      changeset
    else
      Changeset.add_error(changeset,
        field: :config,
        message:
          "#{label}.sandbox.#{key} must be one of #{Enum.map_join(valid, ", ", &Atom.to_string/1)}; " <>
            "got: #{inspect(backend)}"
      )
    end
  end

  defp validate_allow_hosts(changeset, nil, _label), do: changeset

  defp validate_allow_hosts(changeset, hosts, label) when is_list(hosts) do
    case Enum.find(hosts, &(not valid_allow_host?(&1))) do
      nil ->
        changeset

      bad ->
        Changeset.add_error(changeset,
          field: :config,
          message:
            "#{label}.sandbox.allow_hosts entries must be host:port " <>
              "(a leading *. wildcard is allowed); got: #{inspect(bad)}"
        )
    end
  end

  defp validate_allow_hosts(changeset, other, label) do
    Changeset.add_error(changeset,
      field: :config,
      message:
        "#{label}.sandbox.allow_hosts must be a list of host:port strings; got: #{inspect(other)}"
    )
  end

  defp valid_allow_host?(entry) when is_binary(entry),
    do: match?({:ok, _}, EgressPolicy.normalize_baseline([entry]))

  defp valid_allow_host?(_), do: false

  defp validate_routing(changeset, nil), do: changeset

  defp validate_routing(changeset, routing) when is_map(routing) do
    changeset
    |> validate_routing_policy(routing)
    |> validate_provider_selection(Map.get(routing, "provider_selection"))
    |> validate_scoring(Map.get(routing, "scoring"))
    |> validate_capability_gates(routing)
    |> validate_floors(Map.get(routing, "floors"))
  end

  defp validate_routing(changeset, _) do
    Changeset.add_error(changeset, field: :config, message: "routing must be a map")
  end

  # bd-40pzpj: `most_quota` routes the implementer to the attached account
  # with the most quota headroom; `failover` (or unset) is today's behaviour.
  # bd-a1ke2c: `review_agent.cross_family` is a plain on/off switch.
  defp validate_cross_family(changeset, %{"cross_family" => value})
       when not is_boolean(value) and not is_nil(value) do
    Changeset.add_error(changeset,
      field: :config,
      message: "review_agent.cross_family must be true or false; got: #{inspect(value)}"
    )
  end

  defp validate_cross_family(changeset, _review_agent), do: changeset

  # bd-57uzkl: the capability hard gate is a plain on/off switch, and a repo's
  # `requires` names only capabilities the matrix knows.
  defp validate_capability_gates(changeset, routing) do
    changeset
    |> validate_capability_switch(Map.get(routing, "capability_gates"))
    |> validate_repo_requires(Map.get(routing, "repos"))
  end

  defp validate_capability_switch(changeset, value) when is_nil(value) or is_boolean(value),
    do: changeset

  defp validate_capability_switch(changeset, value) do
    Changeset.add_error(changeset,
      field: :config,
      message: "routing.capability_gates must be true or false; got: #{inspect(value)}"
    )
  end

  defp validate_repo_requires(changeset, nil), do: changeset

  defp validate_repo_requires(changeset, %{} = repos) do
    known = Arbiter.Agents.CapabilityMatrix.capabilities()

    Enum.reduce(repos, changeset, fn
      {repo, %{} = entry}, acc ->
        case Map.get(entry, "requires") do
          nil ->
            acc

          requires when is_list(requires) ->
            if Enum.all?(requires, &(&1 in known)),
              do: acc,
              else: requires_error(acc, repo, requires, known)

          other ->
            requires_error(acc, repo, other, known)
        end

      {repo, other}, acc ->
        Changeset.add_error(acc,
          field: :config,
          message: "routing.repos.#{repo} must be a map; got: #{inspect(other)}"
        )
    end)
  end

  defp validate_repo_requires(changeset, other) do
    Changeset.add_error(changeset,
      field: :config,
      message: "routing.repos must be a map; got: #{inspect(other)}"
    )
  end

  defp requires_error(changeset, repo, got, known) do
    Changeset.add_error(changeset,
      field: :config,
      message:
        "routing.repos.#{repo}.requires must be a list of #{Enum.join(known, ", ")}; " <>
          "got: #{inspect(got)}"
    )
  end

  # bd-adtnto: `routing.scoring.*` acts only under `provider_selection: scored`.
  defp validate_scoring(changeset, nil), do: changeset

  defp validate_scoring(changeset, %{} = scoring) do
    changeset
    |> validate_scoring_mode(Map.get(scoring, "mode"))
    |> validate_time_weight(Map.get(scoring, "time_weight"))
    |> validate_scoring_bool(Map.get(scoring, "competence"), "routing.scoring.competence")
    |> validate_scoring_bool(
      Map.get(scoring, "reviewer_coupling"),
      "routing.scoring.reviewer_coupling"
    )
  end

  defp validate_scoring(changeset, other) do
    Changeset.add_error(changeset,
      field: :config,
      message: "routing.scoring must be a map; got: #{inspect(other)}"
    )
  end

  defp validate_scoring_bool(changeset, value, _field) when is_boolean(value) or is_nil(value),
    do: changeset

  defp validate_scoring_bool(changeset, value, field) do
    Changeset.add_error(changeset,
      field: :config,
      message: "#{field} must be true or false; got: #{inspect(value)}"
    )
  end

  defp validate_scoring_mode(changeset, mode) when mode in [nil, "shadow", "enforce"],
    do: changeset

  defp validate_scoring_mode(changeset, mode) do
    Changeset.add_error(changeset,
      field: :config,
      message: "routing.scoring.mode must be shadow or enforce; got: #{inspect(mode)}"
    )
  end

  defp validate_time_weight(changeset, nil), do: changeset

  defp validate_time_weight(changeset, %{} = table) do
    valid? = fn {key, value} ->
      key in ~w(P0 P1 P2 P3 P4) and is_number(value) and value >= 0
    end

    if Enum.all?(table, valid?),
      do: changeset,
      else:
        Changeset.add_error(changeset,
          field: :config,
          message:
            "routing.scoring.time_weight must map P0..P4 to non-negative numbers; " <>
              "got: #{inspect(table)}"
        )
  end

  defp validate_time_weight(changeset, other) do
    Changeset.add_error(changeset,
      field: :config,
      message: "routing.scoring.time_weight must be a map; got: #{inspect(other)}"
    )
  end

  # bd-c675ny: the routing floors. A floor that silently failed to parse would
  # be a floor that silently did not hold, so every malformed shape is refused.
  defp validate_floors(changeset, nil), do: changeset

  defp validate_floors(changeset, %{} = floors) do
    changeset
    |> validate_policy_floor(Map.get(floors, "policy_floor"))
    |> validate_repo_floors(Map.get(floors, "repos"))
  end

  defp validate_floors(changeset, other) do
    Changeset.add_error(changeset,
      field: :config,
      message: "routing.floors must be a map; got: #{inspect(other)}"
    )
  end

  defp validate_policy_floor(changeset, value) when is_nil(value) or is_boolean(value),
    do: changeset

  defp validate_policy_floor(changeset, value) do
    Changeset.add_error(changeset,
      field: :config,
      message: "routing.floors.policy_floor must be true or false; got: #{inspect(value)}"
    )
  end

  defp validate_repo_floors(changeset, nil), do: changeset

  defp validate_repo_floors(changeset, %{} = repos) do
    ladder = Arbiter.Agents.Floors.ladder()

    Enum.reduce(repos, changeset, fn
      {repo, %{} = entry}, acc ->
        case Map.get(entry, "min_model_tier") do
          tier when is_binary(tier) ->
            if tier in ladder, do: acc, else: floor_tier_error(acc, repo, tier, ladder)

          other ->
            floor_tier_error(acc, repo, other, ladder)
        end

      {repo, other}, acc ->
        Changeset.add_error(acc,
          field: :config,
          message: "routing.floors.repos.#{repo} must be a map; got: #{inspect(other)}"
        )
    end)
  end

  defp validate_repo_floors(changeset, other) do
    Changeset.add_error(changeset,
      field: :config,
      message: "routing.floors.repos must be a map; got: #{inspect(other)}"
    )
  end

  defp floor_tier_error(changeset, repo, got, ladder) do
    Changeset.add_error(changeset,
      field: :config,
      message:
        "routing.floors.repos.#{repo}.min_model_tier must be one of #{Enum.join(ladder, ", ")}; " <>
          "got: #{inspect(got)}"
    )
  end

  defp validate_provider_selection(changeset, nil), do: changeset

  defp validate_provider_selection(changeset, selection) do
    valid = Arbiter.Agents.ProviderRouting.valid_selections()

    if selection in valid do
      changeset
    else
      Changeset.add_error(changeset,
        field: :config,
        message:
          "routing.provider_selection must be one of #{Enum.join(valid, ", ")}; " <>
            "got: #{inspect(selection)}"
      )
    end
  end

  defp validate_routing_policy(changeset, routing) do
    valid_policies = Arbiter.Agents.Routing.valid_policies()

    case Map.get(routing, "policy") do
      nil ->
        changeset

      policy ->
        if policy in valid_policies do
          changeset
        else
          Changeset.add_error(changeset,
            field: :config,
            message:
              "routing.policy must be one of #{Enum.join(valid_policies, ", ")}; got: #{inspect(policy)}"
          )
        end
    end
  end

  # bd-cut6uv: only `require_ci_green` is checked here; the rest of the `review`
  # block (`required`, `rounds`) has always been read leniently.
  defp validate_review(changeset, %{} = review) do
    changeset
    |> validate_boolean_setting(review, "require_ci_green", "review.require_ci_green")
    |> validate_review_repos(Map.get(review, "repos"))
  end

  defp validate_review(changeset, _), do: changeset

  defp validate_review_repos(changeset, %{} = repos) do
    Enum.reduce(repos, changeset, fn
      {repo, %{} = entry}, acc ->
        validate_boolean_setting(
          acc,
          entry,
          "require_ci_green",
          "review.repos.#{repo}.require_ci_green"
        )

      {repo, _other}, acc ->
        Changeset.add_error(acc, field: :config, message: "review.repos.#{repo} must be a map")
    end)
  end

  defp validate_review_repos(changeset, nil), do: changeset

  defp validate_review_repos(changeset, _) do
    Changeset.add_error(changeset, field: :config, message: "review.repos must be a map")
  end

  defp validate_boolean_setting(changeset, map, key, label) do
    case Map.fetch(map, key) do
      :error ->
        changeset

      {:ok, v} when is_boolean(v) or v in ["true", "false"] ->
        changeset

      {:ok, v} ->
        Changeset.add_error(changeset,
          field: :config,
          message: "#{label} must be true or false; got: #{inspect(v)}"
        )
    end
  end

  defp validate_review_gate(changeset, nil), do: changeset

  defp validate_review_gate(changeset, review_gate) when is_map(review_gate) do
    changeset
    |> validate_positive_int(review_gate, "max_rounds", "review_gate.max_rounds")
    |> validate_positive_int(review_gate, "timeout_ms", "review_gate.timeout_ms")
    |> validate_non_negative_int(
      review_gate,
      "max_fix_rounds",
      "review_gate.max_fix_rounds"
    )
  end

  defp validate_review_gate(changeset, _) do
    Changeset.add_error(changeset, field: :config, message: "review_gate must be a map")
  end

  # bd-4qjl0q: the notes gate's send-back budget. Zero is meaningful — it
  # escalates on the first blank-notes completion without a nudge.
  defp validate_notes_gate(changeset, nil), do: changeset

  defp validate_notes_gate(changeset, notes_gate) when is_map(notes_gate) do
    validate_non_negative_int(changeset, notes_gate, "nudge_cap", "notes_gate.nudge_cap")
  end

  defp validate_notes_gate(changeset, _) do
    Changeset.add_error(changeset, field: :config, message: "notes_gate must be a map")
  end

  # A config value that, when present, must be a positive integer (or its
  # stringified JSON form). Absent → no-op. Used for review_gate.max_rounds,
  # review_gate.timeout_ms and the loop.evidence_bar thresholds.
  defp validate_positive_int(changeset, map, key, label) do
    case Map.get(map, key) do
      nil ->
        changeset

      n when is_integer(n) and n > 0 ->
        changeset

      s when is_binary(s) ->
        case Integer.parse(s) do
          {n, ""} when n > 0 ->
            changeset

          _ ->
            Changeset.add_error(changeset,
              field: :config,
              message: "#{label} must be a positive integer; got: #{inspect(s)}"
            )
        end

      other ->
        Changeset.add_error(changeset,
          field: :config,
          message: "#{label} must be a positive integer; got: #{inspect(other)}"
        )
    end
  end

  # bd-a9zb7w: `review_gate.max_fix_rounds`'s twin of `validate_positive_int/4`.
  # Zero is meaningful here (it turns the auto fix round off), so it must be
  # accepted rather than rejected as "not positive".
  defp validate_non_negative_int(changeset, map, key, label) do
    case Map.get(map, key) do
      nil ->
        changeset

      n when is_integer(n) and n >= 0 ->
        changeset

      s when is_binary(s) ->
        case Integer.parse(s) do
          {n, ""} when n >= 0 ->
            changeset

          _ ->
            Changeset.add_error(changeset,
              field: :config,
              message: "#{label} must be a non-negative integer; got: #{inspect(s)}"
            )
        end

      other ->
        Changeset.add_error(changeset,
          field: :config,
          message: "#{label} must be a non-negative integer; got: #{inspect(other)}"
        )
    end
  end

  # bd-9j2g3x: the loop-engineering evidence bar. Absent keys fall back to
  # `Arbiter.Loop.default_evidence_bar/0` (3 incidents / 2 distinct tasks), which
  # is the bar `docs/loop-review.md` documents.
  defp validate_loop(changeset, nil), do: changeset

  defp validate_loop(changeset, loop) when is_map(loop) do
    changeset
    |> validate_evidence_bar(Map.get(loop, "evidence_bar"))
    |> validate_loop_ci(Map.get(loop, "ci"))
    |> validate_autonomy(loop)
  end

  defp validate_loop(changeset, _) do
    Changeset.add_error(changeset, field: :config, message: "loop must be a map")
  end

  defp validate_evidence_bar(changeset, nil), do: changeset

  defp validate_evidence_bar(changeset, bar) when is_map(bar) do
    changeset
    |> validate_positive_int(bar, "min_incidents", "loop.evidence_bar.min_incidents")
    |> validate_positive_int(bar, "min_distinct_tasks", "loop.evidence_bar.min_distinct_tasks")
  end

  defp validate_evidence_bar(changeset, _) do
    Changeset.add_error(changeset, field: :config, message: "loop.evidence_bar must be a map")
  end

  # bd-cuu8n3: the loop analyser's CI section — the lint share over which a
  # repo gets a `repo_doc_patch` proposal, the sample floor, and per-repo
  # check commands. `Arbiter.Loop.ci_config/1` also falls back leniently, but
  # a typo here should fail loudly at write time rather than silently revert
  # to the default threshold.
  defp validate_loop_ci(changeset, nil), do: changeset

  defp validate_loop_ci(changeset, ci) when is_map(ci) do
    changeset
    |> validate_loop_fraction(Map.get(ci, "lint_share_threshold"), "loop.ci.lint_share_threshold")
    |> validate_positive_int(ci, "min_fix_passes", "loop.ci.min_fix_passes")
    |> validate_check_commands(Map.get(ci, "check_commands"))
    |> validate_positive_int(
      ci,
      "flake_recurrence_threshold",
      "loop.ci.flake_recurrence_threshold"
    )
  end

  defp validate_loop_ci(changeset, _) do
    Changeset.add_error(changeset, field: :config, message: "loop.ci must be a map")
  end

  defp validate_loop_fraction(changeset, nil, _label), do: changeset

  defp validate_loop_fraction(changeset, value, label) do
    if fraction?(value) do
      changeset
    else
      Changeset.add_error(changeset,
        field: :config,
        message: "#{label} must be a number in (0, 1]; got: #{inspect(value)}"
      )
    end
  end

  defp validate_check_commands(changeset, nil), do: changeset

  defp validate_check_commands(changeset, cmds) do
    if is_map(cmds) and
         Enum.all?(cmds, fn {k, v} -> is_binary(k) and is_binary(v) and v != "" end) do
      changeset
    else
      Changeset.add_error(changeset,
        field: :config,
        message: "loop.ci.check_commands must map repo names to command strings"
      )
    end
  end

  # bd-6edc0u: Stage 3 autonomous routing. The opt-in must be a real boolean —
  # a `"true"` string reads as off to `Arbiter.Loop.Canary.enabled?/1`, and an
  # operator who typed one would have no way of knowing their kill switch was
  # never armed in the first place. The sample floor may be raised, never
  # lowered: a canary judged on fewer than 20 dispatches is judging noise.
  defp validate_autonomy(changeset, loop) do
    changeset
    |> validate_autonomy_flag(Map.get(loop, "autonomous_routing_enabled"))
    |> validate_auto_promote(Map.get(loop, "canary_auto_promote"))
    |> validate_canary_block(Map.get(loop, "canary"))
    |> validate_canary_min_dispatches(Map.get(loop, "canary_min_dispatches"))
    |> validate_canary_tolerance(Map.get(loop, "canary_regression_tolerance"))
    |> validate_canary_max_age(Map.get(loop, "canary_max_age_days"))
  end

  defp validate_autonomy_flag(changeset, nil), do: changeset
  defp validate_autonomy_flag(changeset, v) when is_boolean(v), do: changeset

  defp validate_autonomy_flag(changeset, other) do
    Changeset.add_error(changeset,
      field: :config,
      message: "loop.autonomous_routing_enabled must be true or false; got: #{inspect(other)}"
    )
  end

  defp validate_auto_promote(changeset, nil), do: changeset
  defp validate_auto_promote(changeset, v) when is_boolean(v), do: changeset

  defp validate_auto_promote(changeset, other) do
    Changeset.add_error(changeset,
      field: :config,
      message: "loop.canary_auto_promote must be true or false; got: #{inspect(other)}"
    )
  end

  defp validate_canary_block(changeset, nil), do: changeset
  defp validate_canary_block(changeset, c) when is_map(c), do: changeset

  defp validate_canary_block(changeset, _),
    do: Changeset.add_error(changeset, field: :config, message: "loop.canary must be a map")

  defp validate_canary_min_dispatches(changeset, nil), do: changeset

  defp validate_canary_min_dispatches(changeset, n) do
    floor = Arbiter.Loop.Canary.min_dispatches()

    if is_integer(n) and n >= floor do
      changeset
    else
      Changeset.add_error(changeset,
        field: :config,
        message: "loop.canary_min_dispatches must be an integer >= #{floor}; got: #{inspect(n)}"
      )
    end
  end

  # The revert threshold itself. `Arbiter.Loop.Canary` clamps whatever it finds
  # into range so a malformed block can never widen the tolerance — but a
  # silently clamped threshold is the one config mistake that could mask the
  # regression Stage 3 exists to catch, so it is refused here instead.
  defp validate_canary_tolerance(changeset, nil), do: changeset

  defp validate_canary_tolerance(changeset, t) do
    ceiling = Arbiter.Loop.Canary.max_regression_tolerance()

    if is_number(t) and t >= 0 and t <= ceiling do
      changeset
    else
      Changeset.add_error(changeset,
        field: :config,
        message:
          "loop.canary_regression_tolerance must be a number between 0 and #{ceiling} " <>
            "(a convergence fraction, not a percentage); got: #{inspect(t)}"
      )
    end
  end

  # How long a canary may run before it expires unjudged. Bounded on both ends:
  # zero would expire every canary on its first tick, and something past a
  # quarter is not a deadline at all.
  defp validate_canary_max_age(changeset, nil), do: changeset

  defp validate_canary_max_age(changeset, n) do
    ceiling = Arbiter.Loop.Canary.max_age_days_ceiling()

    if is_integer(n) and n >= 1 and n <= ceiling do
      changeset
    else
      Changeset.add_error(changeset,
        field: :config,
        message:
          "loop.canary_max_age_days must be an integer between 1 and #{ceiling}; got: #{inspect(n)}"
      )
    end
  end

  defp validate_conductor(changeset, nil), do: changeset

  defp validate_conductor(changeset, conductor) when is_map(conductor) do
    case Map.get(conductor, "max_concurrent") do
      nil ->
        changeset

      n when is_integer(n) and n > 0 ->
        changeset

      s when is_binary(s) ->
        case Integer.parse(s) do
          {n, ""} when n > 0 ->
            changeset

          _ ->
            Changeset.add_error(changeset,
              field: :config,
              message: "conductor.max_concurrent must be a positive integer; got: #{inspect(s)}"
            )
        end

      other ->
        Changeset.add_error(changeset,
          field: :config,
          message: "conductor.max_concurrent must be a positive integer; got: #{inspect(other)}"
        )
    end
  end

  defp validate_conductor(changeset, _) do
    Changeset.add_error(changeset, field: :config, message: "conductor must be a map")
  end

  # "auto" (review + post), "report_only"/"propose" (review + report, await
  # greenlight — infra default, bd-36qzgx), "flag"/"notify" (escalate, no
  # review), "off"/"never"/"disabled" (hard opt-out: refuse to dispatch a
  # reviewer at all, bd-7opdaf).
  @valid_automation_modes ~w[auto report_only propose flag notify off never disabled]

  @doc "Valid `review_automation.default` / `repo_overrides` value strings."
  @spec valid_review_automation_modes() :: [String.t()]
  def valid_review_automation_modes, do: @valid_automation_modes

  defp validate_review_automation(changeset, nil), do: changeset

  # Pre-existing complexity 12 — baselined when bd-4x2yhq first
  # wired Credo up. Thresholds stay at the tool's own default so new
  # code is held to it; see the note in .credo.exs.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp validate_review_automation(changeset, block) when is_map(block) do
    changeset
    |> then(fn cs ->
      case Map.get(block, "default") do
        nil ->
          cs

        mode ->
          if mode in @valid_automation_modes do
            cs
          else
            Changeset.add_error(cs,
              field: :config,
              message:
                "review_automation.default must be one of #{Enum.join(@valid_automation_modes, ", ")}; got: #{inspect(mode)}"
            )
          end
      end
    end)
    |> then(fn cs ->
      case Map.get(block, "auto_authors") do
        nil ->
          cs

        list when is_list(list) ->
          invalid = Enum.reject(list, &is_binary/1)

          if invalid == [] do
            cs
          else
            Changeset.add_error(cs,
              field: :config,
              message: "review_automation.auto_authors must be a list of strings"
            )
          end

        _ ->
          Changeset.add_error(cs,
            field: :config,
            message: "review_automation.auto_authors must be a list of strings"
          )
      end
    end)
    |> then(fn cs ->
      case Map.get(block, "repo_overrides") do
        nil ->
          cs

        overrides when is_map(overrides) ->
          invalid = Enum.reject(overrides, fn {_k, v} -> v in @valid_automation_modes end)

          if invalid == [] do
            cs
          else
            Changeset.add_error(cs,
              field: :config,
              message:
                "review_automation.repo_overrides values must each be one of " <>
                  "#{Enum.join(@valid_automation_modes, ", ")}"
            )
          end

        _ ->
          Changeset.add_error(cs,
            field: :config,
            message: "review_automation.repo_overrides must be a map"
          )
      end
    end)
  end

  defp validate_review_automation(changeset, _) do
    Changeset.add_error(changeset, field: :config, message: "review_automation must be a map")
  end

  # Quota-aware dispatch throttle config (bd-7cd38f, bd-1tuxv8):
  #   * on_exhaustion ∈ {"throttle","continue"}
  #   * overage_alert_usd a positive number (or its JSON string form)
  #   * throttle_threshold a number in (0, 1] — the 5h/session window ceiling
  #   * weekly_threshold a number in (0, 1] — the 7d/weekly window ceiling
  #   * weekly_warning_policy ∈ {"ignore","hold"} — what a 7d `allowed_warning`
  #     does (default "ignore"; see Arbiter.Quota.Gate.weekly_warning_policy/1)
  #   * threshold_mode ∈ {"flat","paced"} (bd-2daof2; default "flat")
  #   * paced_floor / weekly_paced_floor numbers in (0, 1] — the paced-mode
  #     head start on the 5h/session and 7d/weekly windows
  #   * pace_exempt_threshold / weekly_pace_exempt_threshold numbers in (0, 1] —
  #     the dedicated cap of the P0 pace exemption on the 5h and 7d windows
  #     (bd-6bxv7h; tighten-only against the account's)
  #   * pace_exempt_priority an integer 0..4, or "none" — narrows the account's
  # `window_seconds` is deliberately not a workspace key: window length belongs
  # to the provider account (see Arbiter.Quota.Gate.window_seconds/2).
  @valid_quota_modes ~w[throttle continue]
  @valid_weekly_warning_policies ~w[ignore hold]
  @valid_threshold_modes ~w[flat paced]

  @doc "Valid `quota.on_exhaustion` value strings."
  @spec valid_quota_modes() :: [String.t()]
  def valid_quota_modes, do: @valid_quota_modes

  # `quota.gate` names an implementation on the `:quota_gate` seam
  # (`Arbiter.Extensions`), so what is valid depends on which extensions are
  # installed. `on_exhaustion` below stays as the core shorthand.
  defp validate_quota_gate(changeset, quota) do
    valid = Arbiter.Extensions.keys(:quota_gate)

    case Map.get(quota, "gate") do
      nil ->
        changeset

      gate when is_binary(gate) ->
        if gate in valid do
          changeset
        else
          Changeset.add_error(changeset,
            field: :config,
            message: "quota.gate must be one of #{Enum.join(valid, ", ")}; got: #{inspect(gate)}"
          )
        end

      other ->
        Changeset.add_error(changeset,
          field: :config,
          message: "quota.gate must be one of #{Enum.join(valid, ", ")}; got: #{inspect(other)}"
        )
    end
  end

  defp validate_quota(changeset, nil), do: changeset

  # Pre-existing complexity 13 — baselined when bd-4x2yhq first
  # wired Credo up. Thresholds stay at the tool's own default so new
  # code is held to it; see the note in .credo.exs.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp validate_quota(changeset, quota) when is_map(quota) do
    changeset
    |> then(fn cs -> validate_quota_gate(cs, quota) end)
    |> then(fn cs ->
      case Map.get(quota, "on_exhaustion") do
        nil ->
          cs

        mode when mode in @valid_quota_modes ->
          cs

        other ->
          Changeset.add_error(cs,
            field: :config,
            message:
              "quota.on_exhaustion must be one of #{Enum.join(@valid_quota_modes, ", ")}; got: #{inspect(other)}"
          )
      end
    end)
    |> then(fn cs ->
      validate_positive_number(cs, quota, "overage_alert_usd")
    end)
    |> then(fn cs -> validate_fraction(cs, quota, "throttle_threshold") end)
    |> then(fn cs -> validate_fraction(cs, quota, "weekly_threshold") end)
    |> then(fn cs -> validate_weekly_warning_policy(cs, quota) end)
    |> then(fn cs -> validate_threshold_mode(cs, quota) end)
    |> then(fn cs -> validate_fraction(cs, quota, "paced_floor") end)
    |> then(fn cs -> validate_fraction(cs, quota, "weekly_paced_floor") end)
    |> then(fn cs -> validate_fraction(cs, quota, "pace_exempt_threshold") end)
    |> then(fn cs -> validate_fraction(cs, quota, "weekly_pace_exempt_threshold") end)
    |> then(fn cs -> validate_pace_exempt_priority(cs, quota) end)
  end

  defp validate_quota(changeset, _) do
    Changeset.add_error(changeset, field: :config, message: "quota must be a map")
  end

  # A 0..1 utilization ceiling that may arrive as a number or its JSON string
  # form (the workspace config form posts strings). Shared by the 5h
  # `throttle_threshold`, the 7d `weekly_threshold` and the paced-mode floors.
  defp validate_fraction(changeset, block, key) do
    case Map.get(block, key) do
      nil -> changeset
      value -> if fraction?(value), do: changeset, else: fraction_error(changeset, key, value)
    end
  end

  defp fraction?(n) when is_number(n), do: n > 0 and n <= 1
  defp fraction?(s) when is_binary(s), do: match?({f, ""} when f > 0 and f <= 1, Float.parse(s))
  defp fraction?(_), do: false

  defp fraction_error(changeset, key, got) do
    Changeset.add_error(changeset,
      field: :config,
      message: "quota.#{key} must be a number in (0, 1]; got: #{inspect(got)}"
    )
  end

  # `0..4` as an integer or its string form, or "none" (switch the exemption off
  # for this workspace). The workspace can only narrow the account's value; the
  # composition is `Arbiter.Quota.Gate.pace_exempt_priority/1`.
  defp validate_pace_exempt_priority(changeset, quota) do
    case Map.get(quota, "pace_exempt_priority") do
      nil -> changeset
      "none" -> changeset
      p when is_integer(p) and p in 0..4 -> changeset
      p when is_binary(p) -> validate_pace_exempt_priority_string(changeset, p)
      other -> pace_exempt_priority_error(changeset, other)
    end
  end

  defp validate_pace_exempt_priority_string(changeset, value) do
    case Integer.parse(value) do
      {n, ""} when n in 0..4 -> changeset
      _ -> pace_exempt_priority_error(changeset, value)
    end
  end

  defp pace_exempt_priority_error(changeset, got) do
    Changeset.add_error(changeset,
      field: :config,
      message:
        "quota.pace_exempt_priority must be an integer in 0..4 or \"none\"; got: #{inspect(got)}"
    )
  end

  defp validate_weekly_warning_policy(changeset, quota) do
    case Map.get(quota, "weekly_warning_policy") do
      nil ->
        changeset

      p when p in @valid_weekly_warning_policies ->
        changeset

      other ->
        Changeset.add_error(changeset,
          field: :config,
          message:
            "quota.weekly_warning_policy must be one of " <>
              "#{Enum.join(@valid_weekly_warning_policies, ", ")}; got: #{inspect(other)}"
        )
    end
  end

  defp validate_threshold_mode(changeset, quota) do
    case Map.get(quota, "threshold_mode") do
      nil ->
        changeset

      m when m in @valid_threshold_modes ->
        changeset

      other ->
        Changeset.add_error(changeset,
          field: :config,
          message:
            "quota.threshold_mode must be one of " <>
              "#{Enum.join(@valid_threshold_modes, ", ")}; got: #{inspect(other)}"
        )
    end
  end

  # Shared validator for a strictly-positive numeric config value that may
  # arrive as a number or its JSON string form.
  defp validate_positive_number(changeset, block, key) do
    case Map.get(block, key) do
      nil ->
        changeset

      n when is_number(n) and n > 0 ->
        changeset

      s when is_binary(s) ->
        case Float.parse(s) do
          {f, ""} when f > 0 ->
            changeset

          _ ->
            Changeset.add_error(changeset,
              field: :config,
              message: "quota.#{key} must be a positive number; got: #{inspect(s)}"
            )
        end

      other ->
        Changeset.add_error(changeset,
          field: :config,
          message: "quota.#{key} must be a positive number; got: #{inspect(other)}"
        )
    end
  end
end
