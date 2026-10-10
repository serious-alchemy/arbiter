defmodule Arbiter.Worker.PermissionsBlock do
  @moduledoc """
  The PERMISSIONS block of a worker's prompt (G14, bd-ld8qde;
  `docs/design/guardrail-profiles.md` §5.2, §5.6): what the ticket's declared
  permissions were projected into, what was withheld and why, and what to do
  about a `403` or a missing credential.

  Rendered only for a **guarded** spawn (`Arbiter.Guardrails.Projection`'s
  `guarded?`); an install with no subject rule gets exactly the prompt it always
  did. The block names granted permissions, the env vars they landed in and the
  hosts they open. It never carries a secret value or the name of a secret.

  A worker never grants itself anything, and an honest "this AC is unmet because
  X was withheld" is the same outcome rule as `EvidenceIntegrity.worker_block/0`.
  """

  alias Arbiter.Guardrails.Projection

  @spec render(Projection.t() | nil) :: String.t()
  def render(%Projection{guarded?: true} = p) do
    """

    PERMISSIONS — what this run was given. Everything not listed here is
    withheld: it is absent from your environment, your mounts and your network,
    not merely forbidden.
    #{granted(p)}#{withheld(p)}
    A `403` from the egress proxy, a missing environment variable or a missing
    key means "not granted". Do not try to work around it: no other credential,
    no other host, no tunnel, no copy of a secret from another place. To ask for
    it, call the MCP tool `permission_request` with the `permission` you need
    (`network:<host>[:<port>]`, `tracker_write`, `secrets:<name>`, `prod_read`
    or `prod_ssh`) and a `reason`. It answers "recorded, not granted": the
    request goes to whoever may grant it, your access does not change, and
    asking is not a violation. Then carry on with what you can. If the task
    cannot be done without it, stop and mark the affected acceptance criteria as
    unmet in your completion notes, saying which permission was missing. You
    cannot grant permissions to yourself.
    """
  end

  def render(_), do: ""

  defp granted(%Projection{role: :reviewer}),
    do: "\nYou are a reviewer: reviewers hold no action permissions.\n"

  defp granted(%Projection{granted: [], hosts: [], env: []}), do: "\nGranted: none.\n"

  defp granted(%Projection{} = p) do
    lines =
      [
        list("Granted", p.granted),
        list(
          "Environment variables granted (set only if the workspace holds the secret)",
          Enum.map(p.env, &elem(&1, 0))
        ),
        list("Hosts reachable through the egress proxy (host:port)", p.hosts),
        list(
          "Local ports forwarded to fixed services",
          Enum.map(p.tunnels, fn {local, _host, _port} -> "127.0.0.1:#{local}" end)
        ),
        ssh(p.ssh),
        list("MCP claims", p.claims)
      ]
      |> Enum.reject(&(&1 == ""))

    "\n" <> Enum.join(lines, "\n") <> "\n"
  end

  defp withheld(%Projection{withheld: []}), do: ""

  defp withheld(%Projection{withheld: withheld}) do
    "\nDeclared on the ticket but withheld:\n" <>
      Enum.map_join(withheld, "\n", fn %{permission: perm, reason: reason} ->
        "  - #{perm}: #{reason}"
      end) <> "\n"
  end

  defp list(_label, []), do: ""
  defp list(label, items), do: "#{label}: #{Enum.join(items, ", ")}"

  defp ssh(nil), do: ""

  defp ssh(%{hosts: hosts}) do
    "SSH: an agent holding the one key you were granted is at $SSH_AUTH_SOCK; " <>
      "it reaches #{Enum.join(hosts, ", ")} only. You can use the key, not read it."
  end
end
