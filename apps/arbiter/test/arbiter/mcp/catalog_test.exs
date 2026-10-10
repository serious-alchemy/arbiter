defmodule Arbiter.MCP.CatalogTest do
  use ExUnit.Case, async: true

  alias Arbiter.MCP.Catalog
  alias Arbiter.MCP.Scope

  @worker %Scope{tier: :worker, workspace_id: "w", task_id: "bd-1"}
  @coordinator %Scope{tier: :coordinator, workspace_id: "w"}

  # The both-tier tools a worker may also reach.
  # `ticket_create` / `dep_add` are here since bd-dtfe9x: a worker files a child
  # of its own task, the same as REST (`Arbiter.Tasks.WorkerFiling`).
  @both_tier ~w(ticket_show inbox_check ticket_update_progress workspace_show quota_get
                message_send notify_list workspace_config_get workspace_config_overview
                workspace_config_schema
                ticket_create dep_add ci_rerun ci_mark_external)

  # Coordinator-only tools; never visible to a worker.
  @coordinator_only ~w(ticket_ready ticket_update ticket_close ticket_reopen ticket_verify
                       ticket_sync_upstream_close dep_remove
                       worker_dispatch
                       worker_resume worker_review worker_stop worker_list worker_show worker_runs
                       worker_log ticket_list
                       tracker_claim tracker_sync tracker_list_issues tracker_create_ticket workspace_list usage_summarize coordinator_inbox
                       coordinator_inbox_clear
                       workspace_config_set workspace_config_unset
                       workspace_standing_order_add workspace_standing_order_remove
                       external_review_list external_review_show review_greenlight
                       loop_pending_list loop_pending_diff loop_pending_apply loop_pending_reject
                       loop_propose_routing loop_analyze loop_propose loop_propose_repo_doc_patch loop_canary_status breaker_list breaker_reset
                       alert_list account_list account_show provider_list usage_events_list
                       usage_calibration account_set
                       memory_pending_list memory_pending_diff memory_pending_apply
                       memory_pending_reject memory_quarantine_list memory_quarantine_restore
                       memory_distill
                       trust_show trust_confirm trust_dismiss)

  # Tools that resolve/authorize a workspace and thus expose the optional
  # `workspace` param. The skill_* tools scope to a workspace (bd-9j6is7).
  @workspace_resolving_tools ~w(ticket_ready coordinator_inbox coordinator_inbox_clear workspace_show
                                quota_get ticket_create worker_list worker_runs ticket_list usage_summarize notify_list
                                tracker_claim tracker_sync tracker_list_issues tracker_create_ticket worker_review workspace_config_get
                                workspace_config_overview workspace_config_set workspace_config_unset
                                workspace_standing_order_add workspace_standing_order_remove
                                external_review_list skill_create skill_update skill_delete skill_list skill_get
                                transcript_capture_stats dep_list
                                loop_pending_list loop_pending_diff loop_pending_apply
                                loop_pending_reject loop_propose_routing loop_analyze loop_propose loop_propose_repo_doc_patch loop_canary_status breaker_list breaker_reset
                                alert_list repo_show usage_events_list usage_calibration)

  describe "tool descriptions" do
    # bd-apj0gq: the description listed five of the six types, but
    # `require_enum(args, "type", Dependency.types())` has always accepted all
    # six — an agent reading the catalog could not discover `conflicts_with`.
    test "dep_add documents every dependency type the tool accepts" do
      %{description: description} =
        @coordinator |> Catalog.visible() |> Enum.find(&(&1.name == "dep_add"))

      for type <- Arbiter.Tasks.Dependency.types() do
        assert description =~ Atom.to_string(type)
      end
    end

    # bd-6bax7s: the description promised a *second* scheduler would not
    # co-dispatch the pair, which a coordinator reasonably read as a general
    # guarantee — and almost all dispatch goes through Autopilot, which
    # ignored the edge. bd-a14qd1 left Autopilot as the only dispatcher, so
    # the description must name it and nothing else.
    test "dep_add names the board scheduler as enforcing conflicts_with" do
      %{description: description} =
        @coordinator |> Catalog.visible() |> Enum.find(&(&1.name == "dep_add"))

      assert description =~ "Autopilot"
      assert description =~ "board scheduler"
      refute description =~ "Conductor"
    end
  end

  describe "visible/1" do
    test "the worker tier sees the both-tier tools but no coordinator-only tool" do
      names = @worker |> Catalog.visible() |> Enum.map(& &1.name)

      assert "permission_request" in names
      refute "ticket_permission_grant" in names

      for tool <- @both_tier, do: assert(tool in names)
      for tool <- @coordinator_only, do: refute(tool in names)
    end

    test "the coordinator tier sees every tool, including the coordinator-only tools" do
      names = @coordinator |> Catalog.visible() |> Enum.map(& &1.name)

      for tool <- @both_tier, do: assert(tool in names)
      for tool <- @coordinator_only, do: assert(tool in names)

      # Every canonical tool the coordinator tier may call (not the worker-only
      # `permission_request`), plus one deprecated `task_*` alias per renamed tool (bd-4jojpw).
      coordinator_tools = Enum.filter(Catalog.all(), &(:coordinator in &1.tiers))
      assert length(names) == length(coordinator_tools) + map_size(Catalog.legacy_aliases())
      refute "permission_request" in names
    end

    test "every tool declares an object input schema" do
      for tool <- Catalog.all() do
        assert tool.input_schema["type"] == "object"
        assert is_map(tool.input_schema["properties"])
      end
    end

    test "workspace-resolving tools advertise an optional `workspace` param" do
      for tool <- Catalog.all() do
        props = tool.input_schema["properties"]

        if tool.name in @workspace_resolving_tools do
          assert is_map(props["workspace"]), "#{tool.name} should have a `workspace` param"
          assert props["workspace"]["type"] == "string"
          # `workspace` is never required — every workspace resolution has a default.
          refute "workspace" in (tool.input_schema["required"] || [])
        else
          refute Map.has_key?(props, "workspace"),
                 "#{tool.name} should not have a `workspace` param"
        end
      end
    end

    test "worker_dispatch exposes a provider enum field and keeps the with_claude alias" do
      assert {:ok, tool} = Catalog.fetch("worker_dispatch")
      props = tool.input_schema["properties"]

      # The schema enum is the handler's accepted set (D-W-10), read from the registry.
      assert props["provider"]["enum"] == Arbiter.Agents.valid_agent_types()
      assert "grok" in props["provider"]["enum"]
      # The deprecated boolean aliases are still advertised so existing callers work.
      assert props["with_claude"]["type"] == "boolean"
      assert props["with_gemini"]["type"] == "boolean"
    end
  end

  describe "call/3 capability gating" do
    test "an unknown tool is a JSON-RPC invalid-params error" do
      assert {:rpc_error, -32_602, message} = Catalog.call(@coordinator, "nope", %{})
      assert message =~ "Unknown tool"
    end

    test "a worker calling a coordinator-only tool is a JSON-RPC not-permitted error" do
      assert {:rpc_error, -32_003, message} = Catalog.call(@worker, "ticket_ready", %{})
      assert message =~ "not permitted"
    end

    # A worker must never be able to apply a fleet-wide change to the very
    # prompts and skills it runs under (bd-9j2g3x).
    test "a worker cannot reach any loop_pending_* tool" do
      for tool <- ~w(loop_pending_list loop_pending_diff loop_pending_apply loop_pending_reject) do
        assert {:rpc_error, -32_003, message} =
                 Catalog.call(@worker, tool, %{"id" => "whatever"})

        assert message =~ "not permitted"
      end
    end
  end

  describe "issue_type descriptions (bd-9s9dqz)" do
    for tool <- ~w(ticket_create ticket_update) do
      test "#{tool} explains research vs task and forbids code work" do
        spec = Enum.find(Catalog.all(), &(&1.name == unquote(tool)))
        desc = get_in(spec.input_schema, ["properties", "issue_type", "description"])

        assert desc =~ "research"
        assert desc =~ "task"
        assert desc =~ "code work"
        assert desc =~ "notes"
      end
    end
  end

  describe "installation_config_set schema" do
    test "key enum matches Settings.Registry.keys/0 and accepts booleans" do
      tool = Enum.find(Catalog.all(), &(&1.name == "installation_config_set"))
      enum = tool.input_schema["properties"]["key"]["enum"]

      assert Enum.sort(enum) ==
               Enum.sort(Enum.map(Arbiter.Settings.Registry.keys(), &to_string/1))

      assert "output_offload_enabled" in enum

      one_of = tool.input_schema["properties"]["value"]["oneOf"]
      assert Enum.any?(one_of, &(&1["type"] == "boolean"))
    end
  end

  describe "installation_config schemas (P-20, D-C-12)" do
    test "installation_config_get's key enum is exactly the registry keys" do
      tool = Enum.find(Catalog.all(), &(&1.name == "installation_config_get"))
      enum = tool.input_schema["properties"]["key"]["enum"]
      assert enum == Arbiter.Settings.Registry.keys()
    end

    test "installation_config_set's value schema can express a string (nodes.public_url)" do
      tool = Enum.find(Catalog.all(), &(&1.name == "installation_config_set"))
      one_of = tool.input_schema["properties"]["value"]["oneOf"]
      assert Enum.any?(one_of, &(&1["type"] == "string"))
    end
  end
end
