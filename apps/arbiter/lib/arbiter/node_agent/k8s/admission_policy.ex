defmodule Arbiter.NodeAgent.K8s.AdmissionPolicy do
  @moduledoc """
  The optional `ValidatingAdmissionPolicy` that bounds the controller's service
  account (`docs/design/remote-workers.md` §7): with it, a compromised controller
  can only create pods shaped like the ones `Arbiter.NodeAgent.K8s.PodSpec` builds.

  The CEL is the design's, **verbatim**, including the two rules K1-A1 added
  (`hostUsers: false`, and non-root, which Pod Security stops enforcing once
  `hostUsers` is false). `validations/2` is the one copy; the manifest renderer
  (K9) and the tests read it. `test/arbiter/node_agent/k8s/admission_policy_test.exs`
  pins three things: every expression is still a substring of the design document,
  every built pod is admitted when the expressions are evaluated (with
  `Arbiter.Test.MiniCel`), and each rule denies the mutation it exists for.

  `<registry>` in the design is the operator's registry prefix, passed in. A
  service image outside `docker.io/library/` and the registry (§6,
  `service_image_allowlist`) widens the image rule, and only that rule, by one
  `startsWith` per prefix.

  Failure is closed: `failurePolicy: Fail`, and an expression over a field that is
  absent (a pod with no `volumes` or `initContainers`) errors, which denies. The
  builder always emits both.
  """

  @controller "arbiter-controller"

  @type validation :: %{name: String.t(), expression: String.t(), message: String.t()}

  @doc "The service-account user the policy applies to."
  @spec controller_username(String.t()) :: String.t()
  def controller_username(namespace \\ "arbiter-workers"),
    do: "system:serviceaccount:#{namespace}:#{@controller}"

  @doc "`variables`: `all` is every container, init containers included, tolerating a pod with none."
  @spec variables() :: [%{name: String.t(), expression: String.t()}]
  def variables do
    [
      %{
        name: "all",
        expression:
          "object.spec.containers + (has(object.spec.initContainers) ? object.spec.initContainers : [])"
      }
    ]
  end

  @doc "`matchConditions`: the policy only judges requests from the controller."
  @spec match_conditions(String.t()) :: [%{name: String.t(), expression: String.t()}]
  def match_conditions(namespace \\ "arbiter-workers") do
    [
      %{
        name: "from-controller",
        expression: "request.userInfo.username == '#{controller_username(namespace)}'"
      }
    ]
  end

  @doc "The seven validations, in the design's order."
  @spec validations(String.t(), [String.t()]) :: [validation()]
  def validations(registry, extra_image_prefixes \\ []) when is_binary(registry) do
    images =
      Enum.map_join(
        ["#{registry}/", "docker.io/library/" | extra_image_prefixes],
        " || ",
        &"c.image.startsWith('#{&1}')"
      )

    [
      %{
        name: "service-account",
        message: "pods run as arbiter-worker with no token",
        expression:
          "object.spec.serviceAccountName == 'arbiter-worker' && object.spec.automountServiceAccountToken == false"
      },
      %{
        name: "host-namespaces",
        message: "no host namespaces",
        expression:
          "!has(object.spec.hostNetwork) && !has(object.spec.hostPID) && !has(object.spec.hostIPC)"
      },
      %{
        name: "volumes",
        message: "only emptyDir and the arbiter-ca ConfigMap: no Secret, hostPath or PVC",
        expression:
          "object.spec.volumes.all(v, has(v.emptyDir) || (has(v.configMap) && v.configMap.name == 'arbiter-ca'))"
      },
      %{
        name: "container-hardening",
        message: "every container is hardened",
        expression:
          "(object.spec.containers + object.spec.initContainers).all(c, has(c.securityContext) && c.securityContext.allowPrivilegeEscalation == false && c.securityContext.capabilities.drop == ['ALL'] && c.securityContext.readOnlyRootFilesystem == true)"
      },
      %{
        name: "images",
        message: "images come from the registry or docker.io/library",
        expression: "(object.spec.containers + object.spec.initContainers).all(c, #{images})"
      },
      %{
        name: "host-users",
        message: "hostUsers must be false",
        expression: "has(object.spec.hostUsers) && object.spec.hostUsers == false"
      },
      %{
        name: "non-root",
        message: "K1-A1: non-root is ours to enforce once hostUsers is false",
        expression:
          "has(object.spec.securityContext) && has(object.spec.securityContext.runAsNonRoot) && object.spec.securityContext.runAsNonRoot && (!has(object.spec.securityContext.runAsUser) || object.spec.securityContext.runAsUser != 0) && variables.all.all(c, !has(c.securityContext) || ((!has(c.securityContext.runAsUser) || c.securityContext.runAsUser != 0) && (!has(c.securityContext.runAsNonRoot) || c.securityContext.runAsNonRoot)))"
      }
    ]
  end

  @doc """
  The policy and its binding as two string-keyed manifests. Options: `registry:`
  (required), `namespace:` (default `arbiter-workers`), `image_prefixes:`.
  """
  @spec manifests(keyword()) :: [map()]
  def manifests(opts) do
    registry = Keyword.fetch!(opts, :registry)
    namespace = Keyword.get(opts, :namespace, "arbiter-workers")
    prefixes = Keyword.get(opts, :image_prefixes, [])

    [
      %{
        "apiVersion" => "admissionregistration.k8s.io/v1",
        "kind" => "ValidatingAdmissionPolicy",
        "metadata" => %{"name" => "arbiter-worker-pods"},
        "spec" => %{
          "failurePolicy" => "Fail",
          "matchConstraints" => %{
            "resourceRules" => [
              %{
                "apiGroups" => [""],
                "apiVersions" => ["v1"],
                "operations" => ["CREATE"],
                "resources" => ["pods"]
              }
            ]
          },
          "variables" =>
            for(v <- variables(), do: %{"name" => v.name, "expression" => v.expression}),
          "matchConditions" =>
            for(
              m <- match_conditions(namespace),
              do: %{"name" => m.name, "expression" => m.expression}
            ),
          "validations" =>
            for(
              v <- validations(registry, prefixes),
              do: %{"expression" => v.expression, "message" => v.message}
            )
        }
      },
      %{
        "apiVersion" => "admissionregistration.k8s.io/v1",
        "kind" => "ValidatingAdmissionPolicyBinding",
        "metadata" => %{"name" => "arbiter-worker-pods"},
        "spec" => %{
          "policyName" => "arbiter-worker-pods",
          "validationActions" => ["Deny"],
          "matchResources" => %{
            "namespaceSelector" => %{
              "matchLabels" => %{"kubernetes.io/metadata.name" => namespace}
            }
          }
        }
      }
    ]
  end
end
