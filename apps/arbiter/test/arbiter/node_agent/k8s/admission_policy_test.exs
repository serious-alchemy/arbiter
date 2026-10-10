defmodule Arbiter.NodeAgent.K8s.AdmissionPolicyTest do
  @moduledoc """
  K4 (bd-7m6quu): the §7 `ValidatingAdmissionPolicy`, with the two K1-A1 rules,
  evaluated verbatim. There is no CEL engine in the project, so the expressions
  run on `Arbiter.Test.MiniCel` (a subset interpreter with CEL's error
  semantics). That is weaker than a real API server and is not a replacement for
  one: K1 ran the same expressions on v1.36.5, and K13 re-runs them on the
  operator's cluster. What this proves in CI is that the builder's pods satisfy
  the design's text, and that each rule denies the mutation it exists for.
  """
  use ExUnit.Case, async: true

  import Arbiter.Test.K8sPodFixtures

  alias Arbiter.NodeAgent.K8s.AdmissionPolicy
  alias Arbiter.Test.MiniCel

  @design Path.expand("../../../../../../docs/design/remote-workers.md", __DIR__)

  defp validations, do: AdmissionPolicy.validations(registry(), ["docker.io/pgsty/"])

  defp bindings(pod, username \\ nil) do
    base = %{
      "object" => pod,
      "request" => %{
        "userInfo" => %{"username" => username || AdmissionPolicy.controller_username()}
      }
    }

    all = MiniCel.eval(hd(AdmissionPolicy.variables()).expression, base)
    variables = with {:ok, v} <- all, do: %{"all" => v}, else: (_ -> %{})
    Map.put(base, "variables", variables)
  end

  defp denied_by(pod) do
    b = bindings(pod)
    for v <- validations(), not MiniCel.admits?(v.expression, b), do: v.name
  end

  defp services_pod do
    build!(run_spec(%{"services" => [%{"preset" => "postgres"}, %{"preset" => "s3"}]}), %{
      service_image_allowlist: ["docker.io/pgsty/"]
    })
  end

  defp normalise(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()

  describe "the expressions are the design's" do
    test "every validation, the variable and the match condition appear verbatim in §7" do
      doc = @design |> File.read!() |> normalise()

      for v <- AdmissionPolicy.validations("<registry>") do
        assert doc =~ normalise(v.expression),
               "#{v.name} drifted from docs/design/remote-workers.md §7"
      end

      for v <- AdmissionPolicy.variables(), do: assert(doc =~ normalise(v.expression))

      assert doc =~
               "request.userInfo.username == 'system:serviceaccount:arbiter-workers:arbiter-controller'"
    end

    test "there are seven validations and their names are unique" do
      names = Enum.map(validations(), & &1.name)
      assert length(names) == 7
      assert names == Enum.uniq(names)
    end

    test "extra image prefixes widen the image rule and nothing else" do
      plain = AdmissionPolicy.validations(registry())
      widened = AdmissionPolicy.validations(registry(), ["docker.io/pgsty/"])
      changed = for {a, b} <- Enum.zip(plain, widened), a != b, do: a.name
      assert changed == ["images"]
    end
  end

  describe "built pods are admitted" do
    test "by every validation, for every shape the builder produces" do
      for pod <- [build!(), build!(run_spec(with_bridges())), services_pod()] do
        assert denied_by(pod) == []
      end
    end

    test "the policy judges only the controller's requests" do
      pod = put_in(build!(), ["spec", "hostUsers"], true)
      [cond] = AdmissionPolicy.match_conditions()

      assert MiniCel.admits?(cond.expression, bindings(pod))

      refute MiniCel.admits?(
               cond.expression,
               bindings(pod, "system:serviceaccount:default:someone")
             )
    end
  end

  # {validation, description, mutation}: each must be denied by exactly its rule (others may also fire).
  defp controls do
    spec = fn pod, k, v -> put_in(pod, ["spec", k], v) end

    sc = fn pod, name, k, v ->
      map_containers(pod, name, &put_in(&1, ["securityContext", k], v))
    end

    [
      {"service-account", "another account", &spec.(&1, "serviceAccountName", "default")},
      {"service-account", "token mounted", &spec.(&1, "automountServiceAccountToken", true)},
      {"service-account", "no token field",
       &update_in(&1, ["spec"], fn s -> Map.delete(s, "automountServiceAccountToken") end)},
      {"host-namespaces", "hostNetwork", &spec.(&1, "hostNetwork", true)},
      {"host-namespaces", "hostPID", &spec.(&1, "hostPID", true)},
      {"host-namespaces", "hostIPC", &spec.(&1, "hostIPC", true)},
      {"volumes", "Secret",
       &add_volume(&1, %{"name" => "s", "secret" => %{"secretName" => "arbiter-node-credential"}})},
      {"volumes", "hostPath", &add_volume(&1, %{"name" => "h", "hostPath" => %{"path" => "/"}})},
      {"volumes", "PVC",
       &add_volume(&1, %{"name" => "p", "persistentVolumeClaim" => %{"claimName" => "x"}})},
      {"volumes", "another ConfigMap",
       &add_volume(&1, %{"name" => "c", "configMap" => %{"name" => "other"}})},
      {"volumes", "fail closed: no volumes field",
       &update_in(&1, ["spec"], fn s -> Map.delete(s, "volumes") end)},
      {"container-hardening", "writable root",
       &sc.(&1, "worker", "readOnlyRootFilesystem", false)},
      {"container-hardening", "privilege escalation",
       &sc.(&1, "worker", "allowPrivilegeEscalation", true)},
      {"container-hardening", "capabilities kept",
       &sc.(&1, "worker", "capabilities", %{"drop" => ["NET_RAW"]})},
      {"container-hardening", "an init container unhardened",
       &sc.(&1, "seed", "readOnlyRootFilesystem", false)},
      {"container-hardening", "a service unhardened",
       &sc.(&1, "svc-postgres", "readOnlyRootFilesystem", false)},
      {"container-hardening", "no securityContext",
       &map_containers(&1, "snapshotter", fn c -> Map.delete(c, "securityContext") end)},
      {"container-hardening", "fail closed: no initContainers field",
       &update_in(&1, ["spec"], fn s -> Map.delete(s, "initContainers") end)},
      {"images", "off-registry worker",
       &map_containers(&1, "worker", fn c ->
         Map.put(c, "image", "evil.example/x@sha256:" <> digest())
       end)},
      {"images", "off-list service",
       &map_containers(&1, "svc-s3", fn c -> Map.put(c, "image", "docker.io/other/silo") end)},
      {"images", "a registry look-alike",
       &map_containers(&1, "worker", fn c ->
         Map.put(c, "image", registry() <> "-evil/x@sha256:" <> digest())
       end)},
      {"host-users", "hostUsers true", &spec.(&1, "hostUsers", true)},
      {"host-users", "hostUsers absent",
       &update_in(&1, ["spec"], fn s -> Map.delete(s, "hostUsers") end)},
      {"non-root", "pod uid 0", &put_in(&1, ["spec", "securityContext", "runAsUser"], 0)},
      {"non-root", "pod runAsNonRoot false",
       &put_in(&1, ["spec", "securityContext", "runAsNonRoot"], false)},
      {"non-root", "pod runAsNonRoot absent",
       &update_in(&1, ["spec", "securityContext"], fn s -> Map.delete(s, "runAsNonRoot") end)},
      {"non-root", "no pod securityContext",
       &update_in(&1, ["spec"], fn s -> Map.delete(s, "securityContext") end)},
      {"non-root", "container uid 0", &sc.(&1, "worker", "runAsUser", 0)},
      {"non-root", "service uid 0", &sc.(&1, "svc-postgres", "runAsUser", 0)},
      {"non-root", "container runAsNonRoot false", &sc.(&1, "worker", "runAsNonRoot", false)}
    ]
  end

  defp map_containers(pod, name, fun) do
    update_in(pod, ["spec"], fn spec ->
      Enum.reduce(["initContainers", "containers"], spec, fn key, spec ->
        case spec do
          %{^key => list} ->
            Map.put(spec, key, Enum.map(list, &if(&1["name"] == name, do: fun.(&1), else: &1)))

          _ ->
            spec
        end
      end)
    end)
  end

  defp add_volume(pod, volume), do: update_in(pod, ["spec", "volumes"], &(&1 ++ [volume]))

  describe "negative controls" do
    test "each mutation is denied by the rule it exists for" do
      base = services_pod()

      for {rule, description, mutate} <- controls() do
        pod = mutate.(base)
        assert pod != base, "#{rule}/#{description}: the mutation changed nothing"

        assert rule in denied_by(pod),
               "#{rule}/#{description}: denied only by #{inspect(denied_by(pod))}"
      end
    end

    test "every validation has a negative control" do
      covered = controls() |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
      assert Enum.map(validations(), & &1.name) -- covered == []
    end

    test "K1-A1: with hostUsers false, the namespace label alone would admit uid 0; this policy does not" do
      pod = put_in(build!(), ["spec", "securityContext", "runAsUser"], 0)
      assert "non-root" in denied_by(pod)
    end
  end

  describe "manifests" do
    test "the policy and binding carry the same expressions and bind the controller's namespace" do
      [policy, binding] =
        AdmissionPolicy.manifests(registry: registry(), image_prefixes: ["docker.io/pgsty/"])

      assert policy["kind"] == "ValidatingAdmissionPolicy"
      assert policy["spec"]["failurePolicy"] == "Fail"

      assert Enum.map(policy["spec"]["validations"], & &1["expression"]) ==
               Enum.map(validations(), & &1.expression)

      assert [%{"name" => "from-controller"}] = policy["spec"]["matchConditions"]
      assert [%{"name" => "all"}] = policy["spec"]["variables"]

      assert binding["spec"]["validationActions"] == ["Deny"]
      assert binding["spec"]["policyName"] == policy["metadata"]["name"]

      assert binding["spec"]["matchResources"]["namespaceSelector"]["matchLabels"] ==
               %{"kubernetes.io/metadata.name" => "arbiter-workers"}
    end

    test "golden: the rendered policy is pinned" do
      yaml =
        AdmissionPolicy.manifests(registry: registry()) |> Enum.map_join("---\n", &golden_yaml/1)

      assert_golden("admission_policy", yaml)
    end
  end

  describe "MiniCel itself (the instrument, so a green run means something)" do
    test "errors absorb under && and || only when the other side decides" do
      env = %{"object" => %{"a" => %{}}}
      assert MiniCel.eval("false && object.nope", env) == {:ok, false}
      assert MiniCel.eval("object.nope && false", env) == {:ok, false}
      assert MiniCel.eval("true || object.nope", env) == {:ok, true}
      assert {:error, _} = MiniCel.eval("true && object.nope", env)
      assert {:error, _} = MiniCel.eval("false || object.nope", env)
    end

    test "has() tests the last key and errors on a missing parent" do
      env = %{"object" => %{"spec" => %{"x" => 1}}}
      assert MiniCel.eval("has(object.spec.x)", env) == {:ok, true}
      assert MiniCel.eval("has(object.spec.y)", env) == {:ok, false}
      assert {:error, _} = MiniCel.eval("has(object.nope.y)", env)
    end

    test "all() is false on any false, an error otherwise-on-error, true on an empty list" do
      env = %{"object" => %{"l" => [%{"v" => 1}, %{}], "e" => []}}
      assert MiniCel.eval("object.e.all(x, x.v == 1)", env) == {:ok, true}
      assert MiniCel.eval("object.l.all(x, x.v == 2)", env) == {:ok, false}
      assert {:error, _} = MiniCel.eval("object.l.all(x, x.v == 1)", env)
    end

    test "lists, concatenation, equality, startsWith and the ternary" do
      env = %{"object" => %{"a" => ["x"], "b" => ["y"], "s" => "docker.io/library/pg"}}
      assert MiniCel.eval("(object.a + object.b) == ['x', 'y']", env) == {:ok, true}
      assert MiniCel.eval("['ALL'] == ['ALL']", env) == {:ok, true}
      assert MiniCel.eval("object.s.startsWith('docker.io/library/')", env) == {:ok, true}
      assert MiniCel.eval("has(object.c) ? object.c : []", env) == {:ok, []}
    end

    test "unsupported syntax is an error, not a pass" do
      assert {:error, _} = MiniCel.eval("1 < 2", %{})
      assert {:error, _} = MiniCel.eval("object.matches('x')", %{"object" => %{}})
    end
  end
end
