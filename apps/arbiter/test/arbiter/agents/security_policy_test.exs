defmodule Arbiter.Agents.SecurityPolicyTest do
  # async: false — one test toggles the :worker_security_policy app env.
  use ExUnit.Case, async: false

  alias Arbiter.Agents.SecurityPolicy
  alias Arbiter.Tasks.Workspace

  describe "base/0 and default/0" do
    test "base is the safe baseline: bypass mode, non-empty safe_defaults, worktree fs" do
      p = SecurityPolicy.base()

      assert p.permissions.mode == :bypass
      assert p.permissions.allow == []
      assert p.permissions.deny == []
      refute Enum.empty?(p.permissions.safe_defaults)
      assert :no_destructive_fs in p.permissions.safe_defaults

      assert p.sandbox == %{
               enabled: true,
               filesystem: :worktree,
               network: true,
               writable_paths: [],
               egress_tunnels: [],
               egress: :open,
               allow_hosts: [],
               backend: :bwrap
             }
    end

    test "default/0 overlays the :worker_security_policy app env" do
      prev = Application.get_env(:arbiter, :worker_security_policy)

      on_exit(fn ->
        case prev do
          nil -> Application.delete_env(:arbiter, :worker_security_policy)
          v -> Application.put_env(:arbiter, :worker_security_policy, v)
        end
      end)

      Application.put_env(:arbiter, :worker_security_policy, %{
        "permissions" => %{"mode" => "strict"},
        "sandbox" => %{"network" => false}
      })

      p = SecurityPolicy.default()
      assert p.permissions.mode == :strict
      assert p.sandbox.network == false
      # safe_defaults still inherited from base (not cleared by the override).
      refute Enum.empty?(p.permissions.safe_defaults)
    end
  end

  describe "resolve/2 precedence" do
    test "nil workspace yields the install default" do
      assert SecurityPolicy.resolve(nil) == SecurityPolicy.default()
    end

    test "workspace config overrides the default and unions deny lists" do
      ws = %Workspace{
        config: %{
          "agent" => %{
            "security" => %{
              "permissions" => %{"mode" => "strict", "deny" => ["Bash(docker:*)"]},
              "sandbox" => %{"network" => false}
            }
          }
        }
      }

      p = SecurityPolicy.resolve(ws)
      assert p.permissions.mode == :strict
      assert "Bash(docker:*)" in p.permissions.deny
      assert p.sandbox.network == false
      assert p.sandbox.filesystem == :worktree
    end

    test "per-dispatch override wins over workspace" do
      ws = %Workspace{
        config: %{"agent" => %{"security" => %{"permissions" => %{"mode" => "strict"}}}}
      }

      p = SecurityPolicy.resolve(ws, %{"permissions" => %{"mode" => "bypass"}})
      assert p.permissions.mode == :bypass
    end

    test "deny unions across workspace and override (additive, not replace)" do
      ws = %Workspace{
        config: %{"agent" => %{"security" => %{"permissions" => %{"deny" => ["A"]}}}}
      }

      p = SecurityPolicy.resolve(ws, %{"permissions" => %{"deny" => ["B"]}})
      assert "A" in p.permissions.deny
      assert "B" in p.permissions.deny
    end

    test "DEPRECATED: workspace config overrides via security.mode (backward compat only)" do
      ws = %Workspace{
        config: %{
          "security" => %{"mode" => "auto"}
        }
      }

      p = SecurityPolicy.resolve(ws)
      assert p.permissions.mode == :auto
    end

    test "DEPRECATED: workspace config overrides via agent.config.security_mode (backward compat only)" do
      ws = %Workspace{
        config: %{
          "agent" => %{
            "config" => %{"security_mode" => "strict"}
          }
        }
      }

      p = SecurityPolicy.resolve(ws)
      assert p.permissions.mode == :strict
    end

    test "canonical path: workspace.config[\"agent\"][\"security\"][\"permissions\"][\"mode\"]" do
      ws = %Workspace{
        config: %{
          "agent" => %{
            "security" => %{
              "permissions" => %{"mode" => "strict"}
            }
          }
        }
      }

      p = SecurityPolicy.resolve(ws)
      assert p.permissions.mode == :strict
    end

    test "canonical path takes precedence over deprecated alt paths" do
      ws = %Workspace{
        config: %{
          "agent" => %{
            "security" => %{
              "permissions" => %{"mode" => "auto"}
            },
            "config" => %{"security_mode" => "strict"}
          },
          "security" => %{"mode" => "bypass"}
        }
      }

      p = SecurityPolicy.resolve(ws)
      # Canonical path should win over the alt paths
      assert p.permissions.mode == :auto
    end
  end

  describe "sandbox.egress_tunnels (bd-cfktou)" do
    test "layers union, malformed entries are dropped, egress_tunnels/1 parses them" do
      ws = %Workspace{
        config: %{
          "agent" => %{
            "security" => %{
              "sandbox" => %{"egress_tunnels" => ["5432:127.0.0.1:5432", "bad", "0:h:1", 3]},
              "repos" => %{
                "device" => %{
                  "sandbox" => %{
                    "egress_tunnels" => ["6379:cache.internal:6379", "5432:127.0.0.1:5432"]
                  }
                }
              }
            }
          }
        }
      }

      p = SecurityPolicy.resolve(ws, nil, "device")

      assert p.sandbox.egress_tunnels == ["5432:127.0.0.1:5432", "6379:cache.internal:6379"]

      assert SecurityPolicy.egress_tunnels(p) ==
               [{5432, "127.0.0.1", 5432}, {6379, "cache.internal", 6379}]

      assert SecurityPolicy.summary(p)["sandbox"]["egress_tunnels"] == p.sandbox.egress_tunnels
    end

    test "none by default" do
      assert SecurityPolicy.egress_tunnels(SecurityPolicy.base()) == []
    end
  end

  describe "sandbox.egress and sandbox.allow_hosts (bd-5yydxh, G10)" do
    defp egress_ws(security, repos \\ nil) do
      security = if repos, do: Map.put(security, "repos", repos), else: security
      %Workspace{config: %{"agent" => %{"security" => security}}}
    end

    test "the default is open with no allow_hosts, so an unconfigured workspace is unchanged" do
      p = SecurityPolicy.resolve(%Workspace{config: %{}})

      assert p.sandbox.egress == :open
      assert p.sandbox.allow_hosts == []
      assert SecurityPolicy.resolve(nil).sandbox.egress == :open
    end

    test "valid_egress_levels/0 lists the three levels, loosest first" do
      assert SecurityPolicy.valid_egress_levels() == [:open, :allowlist, :none]
    end

    test "installation (app env) -> workspace -> repo -> dispatch: egress is replaced by the highest layer" do
      prev = Application.get_env(:arbiter, :worker_security_policy)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:arbiter, :worker_security_policy, prev),
          else: Application.delete_env(:arbiter, :worker_security_policy)
      end)

      Application.put_env(:arbiter, :worker_security_policy, %{sandbox: %{egress: :allowlist}})

      ws = %Workspace{config: %{}}
      assert SecurityPolicy.resolve(ws).sandbox.egress == :allowlist

      ws =
        egress_ws(%{"sandbox" => %{"egress" => "none"}}, %{
          "tonic" => %{"sandbox" => %{"egress" => "open"}}
        })

      assert SecurityPolicy.resolve(ws).sandbox.egress == :none
      assert SecurityPolicy.resolve(ws, %{}, "tonic").sandbox.egress == :open
      assert SecurityPolicy.resolve(ws, %{}, "other").sandbox.egress == :none

      assert SecurityPolicy.resolve(ws, %{"sandbox" => %{"egress" => "allowlist"}}, "tonic").sandbox.egress ==
               :allowlist
    end

    test "allow_hosts union across installation, workspace, repo and dispatch, de-duplicated" do
      ws =
        egress_ws(
          %{"sandbox" => %{"allow_hosts" => ["repo.hex.pm:443", "builds.hex.pm:443"]}},
          %{
            "tonic" => %{
              "sandbox" => %{"allow_hosts" => ["repo.hex.pm:443", "*.example.org:443"]}
            }
          }
        )

      assert SecurityPolicy.resolve(ws).sandbox.allow_hosts == [
               "repo.hex.pm:443",
               "builds.hex.pm:443"
             ]

      assert SecurityPolicy.resolve(ws, %{}, "tonic").sandbox.allow_hosts ==
               ["repo.hex.pm:443", "builds.hex.pm:443", "*.example.org:443"]

      assert SecurityPolicy.resolve(
               ws,
               %{"sandbox" => %{"allow_hosts" => ["api.x.io:443"]}},
               "tonic"
             ).sandbox.allow_hosts ==
               ["repo.hex.pm:443", "builds.hex.pm:443", "*.example.org:443", "api.x.io:443"]
    end

    test "egress is independent of security.mode: setting one never moves the other" do
      ws =
        egress_ws(%{
          "permissions" => %{"mode" => "strict"},
          "sandbox" => %{"egress" => "allowlist"}
        })

      p = SecurityPolicy.resolve(ws)
      assert {p.permissions.mode, p.sandbox.egress} == {:strict, :allowlist}

      p = SecurityPolicy.resolve(ws, %{"permissions" => %{"mode" => "bypass"}})
      assert {p.permissions.mode, p.sandbox.egress} == {:bypass, :allowlist}

      p = SecurityPolicy.resolve(ws, %{"sandbox" => %{"egress" => "open"}})
      assert {p.permissions.mode, p.sandbox.egress} == {:strict, :open}
    end

    test "an unknown egress value is ignored: the inherited level survives" do
      ws =
        egress_ws(%{"sandbox" => %{"egress" => "allowlist"}}, %{
          "r" => %{"sandbox" => %{"egress" => "alowlist"}}
        })

      assert SecurityPolicy.resolve(ws, %{}, "r").sandbox.egress == :allowlist

      assert SecurityPolicy.merge(SecurityPolicy.base(), %{sandbox: %{egress: 3}}).sandbox.egress ==
               :open
    end

    test "malformed allow_hosts entries are dropped, valid ones kept" do
      p =
        SecurityPolicy.merge(SecurityPolicy.base(), %{
          "sandbox" => %{
            "allow_hosts" => [
              "repo.hex.pm:443",
              "no-port",
              "bad host:1",
              "",
              7,
              "*.hex.pm:443",
              "*:443"
            ]
          }
        })

      assert p.sandbox.allow_hosts == ["repo.hex.pm:443", "*.hex.pm:443"]
    end

    test "summary/1 reports egress and allow_hosts" do
      p =
        SecurityPolicy.merge(SecurityPolicy.base(), %{
          sandbox: %{egress: :none, allow_hosts: ["repo.hex.pm:443"]}
        })

      sandbox = SecurityPolicy.summary(p)["sandbox"]

      assert sandbox["egress"] == "none"
      assert SecurityPolicy.summary(p)["egress"] == "none"
      assert sandbox["allow_hosts"] == ["repo.hex.pm:443"]
      assert SecurityPolicy.summary(SecurityPolicy.base())["sandbox"]["egress"] == "open"
    end

    test "repo_egress/1 gives the effective level for every repo override" do
      ws =
        egress_ws(
          %{"sandbox" => %{"egress" => "allowlist"}},
          %{"a" => %{"sandbox" => %{"egress" => "none"}}, "b" => %{}}
        )

      assert SecurityPolicy.repo_egress(ws) == %{"a" => "none", "b" => "allowlist"}
      assert SecurityPolicy.repo_egress(%Workspace{config: %{}}) == %{}
      assert SecurityPolicy.repo_egress(nil) == %{}
    end

    test "one_line/1 names a non-open egress level and stays silent for open" do
      refute SecurityPolicy.one_line(SecurityPolicy.base()) =~ "egress"

      p = SecurityPolicy.merge(SecurityPolicy.base(), %{sandbox: %{egress: :allowlist}})
      assert SecurityPolicy.one_line(p) =~ "egress=allowlist"
    end
  end

  describe "sandbox.backend (bd-btcdrf, P2)" do
    defp backend_ws(security, repos \\ nil) do
      security = if repos, do: Map.put(security, "repos", repos), else: security
      %Workspace{config: %{"agent" => %{"security" => security}}}
    end

    setup do
      prev = Application.get_env(:arbiter, :worker_security_policy)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:arbiter, :worker_security_policy, prev),
          else: Application.delete_env(:arbiter, :worker_security_policy)
      end)
    end

    test "the default is bwrap, so an unconfigured workspace is unchanged" do
      assert SecurityPolicy.base().sandbox.backend == :bwrap
      assert SecurityPolicy.resolve(%Workspace{config: %{}}).sandbox.backend == :bwrap
      assert SecurityPolicy.resolve(nil).sandbox.backend == :bwrap
      assert SecurityPolicy.sandbox_backend(SecurityPolicy.default()) == :bwrap
    end

    test "valid_sandbox_backends/0 lists the backends, loosest first" do
      assert SecurityPolicy.valid_sandbox_backends() == [:bwrap, :podman]
    end

    test "a layer can raise bwrap to podman, as a string or an atom" do
      assert SecurityPolicy.resolve(backend_ws(%{"sandbox" => %{"backend" => "podman"}})).sandbox.backend ==
               :podman

      assert SecurityPolicy.merge(SecurityPolicy.base(), %{sandbox: %{backend: :podman}}).sandbox.backend ==
               :podman
    end

    test "most restrictive wins: no later layer can drop podman back to bwrap" do
      Application.put_env(:arbiter, :worker_security_policy, %{sandbox: %{backend: :podman}})

      ws =
        backend_ws(%{"sandbox" => %{"backend" => "bwrap"}}, %{
          "tonic" => %{"sandbox" => %{"backend" => "bwrap"}}
        })

      assert SecurityPolicy.resolve(ws).sandbox.backend == :podman

      assert SecurityPolicy.resolve(ws, %{"sandbox" => %{"backend" => "bwrap"}}, "tonic").sandbox.backend ==
               :podman
    end

    test "podman set at any one layer survives every layer above it" do
      ws = backend_ws(%{}, %{"tonic" => %{"sandbox" => %{"backend" => "podman"}}})

      assert SecurityPolicy.resolve(ws).sandbox.backend == :bwrap
      assert SecurityPolicy.resolve(ws, %{}, "tonic").sandbox.backend == :podman
      assert SecurityPolicy.resolve(ws, %{}, "other").sandbox.backend == :bwrap

      ws = backend_ws(%{"sandbox" => %{"backend" => "podman"}})

      assert SecurityPolicy.resolve(ws, %{"sandbox" => %{"backend" => "bwrap"}}).sandbox.backend ==
               :podman
    end

    test "an unknown value is ignored, so the inherited backend survives" do
      for bad <- ["docker", "", 3, nil, %{}, ["podman"]] do
        p = SecurityPolicy.merge(SecurityPolicy.base(), %{"sandbox" => %{"backend" => bad}})
        assert p.sandbox.backend == :bwrap

        p =
          SecurityPolicy.merge(SecurityPolicy.merge(p, %{sandbox: %{backend: :podman}}), %{
            "sandbox" => %{"backend" => bad}
          })

        assert p.sandbox.backend == :podman
      end
    end

    test "a policy struct without the key (built before it existed) reads as bwrap" do
      legacy = %SecurityPolicy{
        permissions: SecurityPolicy.base().permissions,
        sandbox: Map.delete(SecurityPolicy.base().sandbox, :backend)
      }

      assert SecurityPolicy.sandbox_backend(legacy) == :bwrap

      assert SecurityPolicy.merge(legacy, %{sandbox: %{backend: :podman}}).sandbox.backend ==
               :podman
    end

    test "setting the backend never moves egress or mode, and vice versa" do
      ws = backend_ws(%{"sandbox" => %{"backend" => "podman"}})
      p = SecurityPolicy.resolve(ws)

      assert p.sandbox.egress == :open
      assert p.permissions.mode == SecurityPolicy.base().permissions.mode

      p = SecurityPolicy.resolve(backend_ws(%{"sandbox" => %{"egress" => "none"}}))
      assert p.sandbox.backend == :bwrap
    end

    test "summary/1 and one_line/1 surface a non-default backend only" do
      assert SecurityPolicy.summary(SecurityPolicy.base())["sandbox"]["backend"] == "bwrap"

      podman = SecurityPolicy.merge(SecurityPolicy.base(), %{sandbox: %{backend: :podman}})
      assert SecurityPolicy.summary(podman)["sandbox"]["backend"] == "podman"
      assert SecurityPolicy.one_line(podman) =~ "sandbox=podman"
      refute SecurityPolicy.one_line(SecurityPolicy.base()) =~ "sandbox="
    end
  end

  describe "egress host classes (bd-5yydxh, design 4.4)" do
    test "infra and toolchain are reachable at none and allowlist; extras and grants only at allowlist" do
      assert SecurityPolicy.egress_classes(:none) == [:infra, :toolchain]
      assert SecurityPolicy.egress_classes(:allowlist) == [:infra, :toolchain, :extras, :grants]

      assert SecurityPolicy.egress_class_allowed?(:none, :infra)
      assert SecurityPolicy.egress_class_allowed?(:none, :toolchain)
      refute SecurityPolicy.egress_class_allowed?(:none, :extras)
      refute SecurityPolicy.egress_class_allowed?(:none, :grants)
      assert SecurityPolicy.egress_class_allowed?(:allowlist, :grants)
    end

    test "open is not filtered by host class: every class is reachable" do
      assert SecurityPolicy.egress_classes(:open) == [:infra, :toolchain, :extras, :grants]
      refute SecurityPolicy.egress_filtered?(:open)
      assert SecurityPolicy.egress_filtered?(:allowlist)
      assert SecurityPolicy.egress_filtered?(:none)
    end

    test "allow_host_class/1 puts registries in toolchain and anything else in extras" do
      assert SecurityPolicy.allow_host_class("repo.hex.pm:443") == :toolchain
      assert SecurityPolicy.allow_host_class("builds.hex.pm:443") == :toolchain
      assert SecurityPolicy.allow_host_class("*.hex.pm:443") == :toolchain
      assert SecurityPolicy.allow_host_class("api.example.com:443") == :extras
      assert SecurityPolicy.allow_host_class("repo.hex.pm.evil.test:443") == :extras
    end

    test "egress_baseline/2: infra always, allow_hosts filtered by the level's classes" do
      base = fn egress ->
        SecurityPolicy.merge(SecurityPolicy.base(), %{
          sandbox: %{egress: egress, allow_hosts: ["repo.hex.pm:443", "api.example.com:443"]}
        })
      end

      infra = ["api.anthropic.com:443"]

      assert SecurityPolicy.egress_baseline(base.(:none), infra) ==
               ["api.anthropic.com:443", "repo.hex.pm:443"]

      assert SecurityPolicy.egress_baseline(base.(:allowlist), infra) ==
               ["api.anthropic.com:443", "repo.hex.pm:443", "api.example.com:443"]

      assert SecurityPolicy.egress_baseline(base.(:open), infra) == :unfiltered
    end

    test "ticket grants are honoured only at allowlist" do
      none = SecurityPolicy.merge(SecurityPolicy.base(), %{sandbox: %{egress: :none}})
      allowlist = SecurityPolicy.merge(SecurityPolicy.base(), %{sandbox: %{egress: :allowlist}})

      assert SecurityPolicy.grants_allowed?(allowlist)
      refute SecurityPolicy.grants_allowed?(none)
    end
  end

  describe "sandbox.writable_paths (bd-5gvqgc)" do
    test "unions across the install, workspace, repo and override layers like allow/deny" do
      prev = Application.get_env(:arbiter, :worker_security_policy)

      Application.put_env(:arbiter, :worker_security_policy, %{
        sandbox: %{writable_paths: ["/opt/install"]}
      })

      on_exit(fn ->
        if is_nil(prev),
          do: Application.delete_env(:arbiter, :worker_security_policy),
          else: Application.put_env(:arbiter, :worker_security_policy, prev)
      end)

      ws = %Workspace{
        config: %{
          "agent" => %{
            "security" => %{
              "sandbox" => %{"writable_paths" => ["~/.cache/rebar3"]},
              "repos" => %{
                "device" => %{"sandbox" => %{"writable_paths" => ["/opt/device", "/opt/install"]}}
              }
            }
          }
        }
      }

      p =
        SecurityPolicy.resolve(ws, %{"sandbox" => %{"writable_paths" => ["/opt/task"]}}, "device")

      assert p.sandbox.writable_paths == [
               "/opt/install",
               "~/.cache/rebar3",
               "/opt/device",
               "/opt/task"
             ]
    end

    test "non-list and non-string entries are ignored" do
      p =
        SecurityPolicy.merge(SecurityPolicy.base(), %{
          "sandbox" => %{"writable_paths" => ["/ok", 3, "", nil]}
        })

      assert p.sandbox.writable_paths == ["/ok"]

      assert SecurityPolicy.merge(p, %{"sandbox" => %{"writable_paths" => "/nope"}}).sandbox.writable_paths ==
               ["/ok"]
    end

    test "summary/1 surfaces it" do
      p = SecurityPolicy.merge(SecurityPolicy.base(), %{sandbox: %{writable_paths: ["/opt/x"]}})
      assert SecurityPolicy.summary(p)["sandbox"]["writable_paths"] == ["/opt/x"]
    end
  end

  describe "resolve/3 per-repo overrides" do
    # A workspace whose `device` repo runs a stricter posture than the
    # workspace-wide default, and adds an extra deny rule.
    defp multi_repo_ws do
      %Workspace{
        config: %{
          "agent" => %{
            "security" => %{
              "permissions" => %{"mode" => "auto", "deny" => ["Bash(docker:*)"]},
              "sandbox" => %{"network" => true},
              "repos" => %{
                "device" => %{
                  "permissions" => %{"mode" => "strict", "deny" => ["Bash(curl:*)"]},
                  "sandbox" => %{"network" => false}
                }
              }
            }
          }
        }
      }
    end

    test "repo override replaces scalar fields for that repo only" do
      ws = multi_repo_ws()

      device = SecurityPolicy.resolve(ws, %{}, "device")
      assert device.permissions.mode == :strict
      assert device.sandbox.network == false

      # A different repo (no override) sees the workspace-wide posture.
      other = SecurityPolicy.resolve(ws, %{}, "server")
      assert other.permissions.mode == :auto
      assert other.sandbox.network == true
    end

    test "repo override unions deny onto the workspace deny (additive)" do
      ws = multi_repo_ws()
      device = SecurityPolicy.resolve(ws, %{}, "device")

      # Both the workspace-wide and repo-specific deny rules are present.
      assert "Bash(docker:*)" in device.permissions.deny
      assert "Bash(curl:*)" in device.permissions.deny

      # The non-overridden repo carries only the workspace-wide deny.
      other = SecurityPolicy.resolve(ws, %{}, "server")
      assert "Bash(docker:*)" in other.permissions.deny
      refute "Bash(curl:*)" in other.permissions.deny
    end

    test "nil/blank repo resolves identically to resolve/2 (backward compatible)" do
      ws = multi_repo_ws()

      base = SecurityPolicy.resolve(ws)
      assert SecurityPolicy.resolve(ws, %{}, nil) == base
      assert SecurityPolicy.resolve(ws, %{}, "") == base
      # Workspace-wide posture, unaffected by the repo block.
      assert base.permissions.mode == :auto
    end

    test "an unknown repo name falls back to the workspace-wide posture" do
      ws = multi_repo_ws()
      p = SecurityPolicy.resolve(ws, %{}, "does-not-exist")
      assert p.permissions.mode == :auto
      assert p.sandbox.network == true
    end

    test "forge-qualified slug matches bare repos key (bd-36p5rh)" do
      ws = multi_repo_ws()

      # Caller has forge-qualified slug; config is keyed by bare name
      device = SecurityPolicy.resolve(ws, %{}, "some-org/device")
      # Should find the per-repo override, not fall back to workspace-wide
      assert device.permissions.mode == :strict
      assert device.sandbox.network == false

      # Non-overridden repo still falls back to workspace-wide
      other = SecurityPolicy.resolve(ws, %{}, "some-org/server")
      assert other.permissions.mode == :auto
      assert other.sandbox.network == true
    end

    test "explicit per-dispatch override still wins over the repo layer" do
      ws = multi_repo_ws()
      p = SecurityPolicy.resolve(ws, %{"permissions" => %{"mode" => "bypass"}}, "device")
      assert p.permissions.mode == :bypass
      # deny from both workspace and repo layers is still unioned under it.
      assert "Bash(docker:*)" in p.permissions.deny
      assert "Bash(curl:*)" in p.permissions.deny
    end

    test "a workspace with no repos block is unaffected by a repo name" do
      ws = %Workspace{
        config: %{"agent" => %{"security" => %{"permissions" => %{"mode" => "strict"}}}}
      }

      assert SecurityPolicy.resolve(ws, %{}, "device") == SecurityPolicy.resolve(ws)
    end
  end

  describe "merge/2 leniency" do
    test "ignores unknown / malformed values, keeping the safer inherited value" do
      p =
        SecurityPolicy.merge(SecurityPolicy.base(), %{
          "permissions" => %{"mode" => "nonsense"},
          "sandbox" => %{"filesystem" => "wormhole", "network" => "not-a-bool"}
        })

      # All fall back to base.
      assert p.permissions.mode == :bypass
      assert p.sandbox.filesystem == :worktree
      assert p.sandbox.network == true
    end

    # bd-4420va: a pinned `safe_defaults` list used to *replace* the baseline
    # wholesale, so a workspace that pinned it before a new category shipped
    # (vstim pinning the 4 categories that existed pre-v0.1.78) silently never
    # got the new ones (:no_public_upload, :no_pr_create, :no_async_wait,
    # :no_gh_publish never applied). The legacy key is now read-but-inert: it
    # no longer narrows the resolved set. `safe_defaults_exclude` is the only
    # supported way to drop a category (see the next describe block).
    test "a legacy pinned safe_defaults list no longer narrows the resolved set" do
      p =
        SecurityPolicy.merge(SecurityPolicy.base(), %{
          "permissions" => %{
            "safe_defaults" => [
              "no_destructive_fs",
              "no_force_push",
              "no_secret_reads",
              "no_outside_writes"
            ]
          }
        })

      assert :no_public_upload in p.permissions.safe_defaults
      assert :no_pr_create in p.permissions.safe_defaults
      assert :no_async_wait in p.permissions.safe_defaults
      assert :no_gh_publish in p.permissions.safe_defaults

      assert Enum.sort(p.permissions.safe_defaults) ==
               Enum.sort(SecurityPolicy.safe_default_categories())
    end

    test "an empty legacy safe_defaults no longer opts the domain out (must exclude by name now)" do
      p =
        SecurityPolicy.merge(SecurityPolicy.base(), %{"permissions" => %{"safe_defaults" => []}})

      assert Enum.sort(p.permissions.safe_defaults) ==
               Enum.sort(SecurityPolicy.safe_default_categories())
    end

    test "unknown category names in safe_defaults_exclude are dropped" do
      p =
        SecurityPolicy.merge(SecurityPolicy.base(), %{
          "permissions" => %{"safe_defaults_exclude" => ["no_force_push", "bogus_category"]}
        })

      refute :no_force_push in p.permissions.safe_defaults
      assert :no_destructive_fs in p.permissions.safe_defaults
    end

    test "accepts atom-keyed override maps (app env / programmatic)" do
      p = SecurityPolicy.merge(SecurityPolicy.base(), %{permissions: %{mode: :strict}})
      assert p.permissions.mode == :strict
    end
  end

  describe "summary/1 and one_line/1" do
    test "summary is JSON-friendly and string-keyed" do
      s = SecurityPolicy.summary(SecurityPolicy.base())

      assert s["mode"] == "bypass"
      assert is_list(s["safe_defaults"])
      assert s["sandbox"]["filesystem"] == "worktree"
      assert s["sandbox"]["network"] == true
    end

    test "one_line summarizes mode, fs, net, deny count" do
      line = SecurityPolicy.one_line(SecurityPolicy.base())
      assert line =~ "bypass"
      assert line =~ "fs=worktree"
      assert line =~ "net=on"
    end

    test "one_line shows net=tools-off when network: false" do
      policy = SecurityPolicy.merge(SecurityPolicy.base(), %{sandbox: %{network: false}})
      line = SecurityPolicy.one_line(policy)
      assert line =~ "net=tools-off"
      refute line =~ "net=off"
    end
  end

  # bd-5xlkkj gave interactive coordinator sessions their own profile. The whole
  # point was that the headless worker's posture does not move with it, so this
  # pins the worker side rather than the new side.
  describe "the headless worker profile is unchanged by the session profile (bd-5xlkkj)" do
    test "base/0 still bypasses the interactive classifier" do
      assert SecurityPolicy.base().permissions.mode == :bypass
      assert SecurityPolicy.default().permissions.mode == :bypass
    end

    test "base/0 still denies the async-wait tools a --print worker cannot use" do
      assert :no_async_wait in SecurityPolicy.base().permissions.safe_defaults

      deny = Arbiter.Agents.Claude.Security.deny_rules(SecurityPolicy.base())
      assert "Monitor" in deny
      assert "ScheduleWakeup" in deny
    end

    test "the worker's generated settings still say bypassPermissions" do
      settings = Arbiter.Agents.Claude.Security.settings(SecurityPolicy.default())
      assert settings["permissions"]["defaultMode"] == "bypassPermissions"
    end
  end

  describe "interactive_session/0 (bd-5xlkkj)" do
    test "runs in auto mode — a human is at the keyboard, so the classifier can ask" do
      assert SecurityPolicy.interactive_session().permissions.mode == :auto
    end

    # bd-80talz: :no_gh_publish is worker-only too. An operator or coordinator
    # session commenting on an issue is ordinary work.
    test "drops only :no_async_wait and :no_gh_publish from the baseline categories" do
      worker = SecurityPolicy.base().permissions.safe_defaults
      session = SecurityPolicy.interactive_session().permissions.safe_defaults

      assert worker -- session == [:no_async_wait, :no_gh_publish]
      assert session -- worker == []
    end

    test "keeps the destructive, secret-read and PR-create denies" do
      deny = Arbiter.Agents.Claude.Security.deny_rules(SecurityPolicy.interactive_session())

      assert "Bash(rm -rf:*)" in deny
      assert "Bash(git push --force:*)" in deny
      assert "Read(**/.env)" in deny
      assert "Edit(~/.ssh/**)" in deny
      assert "Bash(gh pr create:*)" in deny
      assert "Bash(glab mr create:*)" in deny
      refute "Monitor" in deny
      refute "ScheduleWakeup" in deny
    end

    test "denies minting a coordinator token from inside the session" do
      deny = Arbiter.Agents.Claude.Security.deny_rules(SecurityPolicy.interactive_session())

      assert "Bash(arb mcp token mint:*)" in deny
    end

    test "does not add the token-mint deny to the worker baseline" do
      deny = Arbiter.Agents.Claude.Security.deny_rules(SecurityPolicy.base())

      refute "Bash(arb mcp token mint:*)" in deny
    end

    test "reads its own config key, not the worker's" do
      previous = Application.get_env(:arbiter, :worker_security_policy)

      Application.put_env(:arbiter, :worker_security_policy, %{
        "permissions" => %{"mode" => "strict"}
      })

      on_exit(fn ->
        if previous do
          Application.put_env(:arbiter, :worker_security_policy, previous)
        else
          Application.delete_env(:arbiter, :worker_security_policy)
        end
      end)

      assert SecurityPolicy.default().permissions.mode == :strict
      assert SecurityPolicy.interactive_session().permissions.mode == :auto
    end
  end

  # bd-80talz: an agy worker uploaded mockup "screenshots" to files.catbox.moe
  # and a public gist on the operator's account, and tried 0x0.st, transfer.sh
  # and envs.sh. Nothing in the default posture stopped it.
  describe "the public upload/paste host baseline (bd-80talz)" do
    test "is a default safe-default category for workers and sessions alike" do
      assert :no_public_upload in SecurityPolicy.safe_default_categories()
      assert :no_public_upload in SecurityPolicy.base().permissions.safe_defaults
      assert :no_public_upload in SecurityPolicy.resolve(nil).permissions.safe_defaults
      assert :no_public_upload in SecurityPolicy.interactive_session().permissions.safe_defaults
    end

    test "the gist/issue-comment denies bind workers, not interactive sessions" do
      assert :no_gh_publish in SecurityPolicy.resolve(nil).permissions.safe_defaults
      refute :no_gh_publish in SecurityPolicy.interactive_session().permissions.safe_defaults

      worker = Arbiter.Agents.Claude.Security.deny_rules(SecurityPolicy.resolve(nil))
      session = Arbiter.Agents.Claude.Security.deny_rules(SecurityPolicy.interactive_session())

      assert "Bash(gh issue comment:*)" in worker
      assert "Bash(gh gist create:*)" in worker
      refute Enum.any?(session, &(&1 =~ "gh issue comment" or &1 =~ "gh gist"))

      # The host denies still bind the session.
      assert "Bash(curl *catbox.moe*)" in session
      assert "WebFetch(domain:*.catbox.moe)" in session
    end

    test "documents at least the hosts the incident used or tried" do
      hosts = SecurityPolicy.public_upload_hosts()

      for host <- ~w(catbox.moe 0x0.st transfer.sh file.io envs.sh pastebin.com) do
        assert host in hosts, "#{host} missing from public_upload_hosts/0"
      end
    end

    test "lists bare registrable domains, so a subdomain rule can be derived from each" do
      for host <- SecurityPolicy.public_upload_hosts() do
        refute String.contains?(host, ["/", "*", " ", ":"]), "#{inspect(host)} is not a bare host"
      end

      # litterbox is catbox's temporary host, litter.catbox.moe — covered by
      # catbox.moe's subdomain rule rather than listed on its own.
      refute "litter.catbox.moe" in SecurityPolicy.public_upload_hosts()
    end
  end

  # bd-4420va: vstim pinned `agent.security.permissions.safe_defaults` to the
  # 4 categories that existed before v0.1.78 (#2061 / bd-80talz added 4 more).
  # A pinned list used to *replace* the baseline, so vstim silently never got
  # :no_public_upload, :no_pr_create, :no_async_wait or :no_gh_publish, with
  # nothing surfacing the gap. `safe_defaults_exclude` is now the only
  # supported way to drop a category by name.
  describe "a pinned safe_defaults list does not opt a workspace out of new categories (bd-4420va)" do
    @vstim_pinned_config %{
      "agent" => %{
        "security" => %{
          "permissions" => %{
            "safe_defaults" => [
              "no_destructive_fs",
              "no_force_push",
              "no_secret_reads",
              "no_outside_writes"
            ]
          }
        }
      }
    }

    test "resolves :no_public_upload (and every other current default) despite the old pinned list" do
      p = SecurityPolicy.resolve(%{config: @vstim_pinned_config})

      for category <- SecurityPolicy.safe_default_categories() do
        assert category in p.permissions.safe_defaults,
               "expected #{category} to still be resolved for a workspace with an old pinned safe_defaults list"
      end
    end

    test "an explicit safe_defaults_exclude still drops a category by name, and is the only way to" do
      config =
        put_in(
          @vstim_pinned_config,
          ["agent", "security", "permissions", "safe_defaults_exclude"],
          ["no_public_upload"]
        )

      p = SecurityPolicy.resolve(%{config: config})

      refute :no_public_upload in p.permissions.safe_defaults
      # Everything else (including the other categories missing from the
      # legacy pinned list) still resolves.
      assert :no_pr_create in p.permissions.safe_defaults
      assert :no_async_wait in p.permissions.safe_defaults
      assert :no_gh_publish in p.permissions.safe_defaults
    end

    test "the resolved summary names the workspace's excluded/missing default categories" do
      config =
        put_in(
          @vstim_pinned_config,
          ["agent", "security", "permissions", "safe_defaults_exclude"],
          ["no_public_upload", "no_secret_reads"]
        )

      summary = SecurityPolicy.resolve(%{config: config}) |> SecurityPolicy.summary()

      assert Enum.sort(summary["safe_defaults_exclude"]) == [
               "no_public_upload",
               "no_secret_reads"
             ]
    end
  end

  describe "mode_source/3 (bd-1abj7u)" do
    test "nil workspace, no override: :install_default" do
      assert SecurityPolicy.mode_source(nil) == {:bypass, :install_default}
    end

    test "nil workspace, install-wide default sets the mode" do
      prev = Application.get_env(:arbiter, :worker_security_policy)

      on_exit(fn ->
        case prev do
          nil -> Application.delete_env(:arbiter, :worker_security_policy)
          v -> Application.put_env(:arbiter, :worker_security_policy, v)
        end
      end)

      Application.put_env(:arbiter, :worker_security_policy, %{
        "permissions" => %{"mode" => "strict"}
      })

      assert SecurityPolicy.mode_source(nil) == {:strict, :install_default}
    end

    test "workspace with no security block: :install_default" do
      ws = %Workspace{config: %{}}
      assert SecurityPolicy.mode_source(ws) == {:bypass, :install_default}
    end

    test "workspace-level mode: :workspace" do
      ws = %Workspace{
        config: %{"agent" => %{"security" => %{"permissions" => %{"mode" => "strict"}}}}
      }

      assert SecurityPolicy.mode_source(ws) == {:strict, :workspace}
    end

    test "repo override mode: :repo" do
      ws = multi_repo_ws()

      assert SecurityPolicy.mode_source(ws, %{}, "device") == {:strict, :repo}
      assert SecurityPolicy.mode_source(ws, %{}, "server") == {:auto, :workspace}
    end

    test "per-dispatch override mode: :dispatch_override" do
      ws = %Workspace{
        config: %{"agent" => %{"security" => %{"permissions" => %{"mode" => "auto"}}}}
      }

      assert SecurityPolicy.mode_source(ws, %{"permissions" => %{"mode" => "bypass"}}) ==
               {:bypass, :dispatch_override}
    end

    test "always matches the mode resolve/3 would have produced" do
      ws = multi_repo_ws()
      override = %{"permissions" => %{"mode" => "bypass"}}

      resolved = SecurityPolicy.resolve(ws, override, "device")
      {mode, _source} = SecurityPolicy.mode_source(ws, override, "device")

      assert resolved.permissions.mode == mode
    end
  end
end
