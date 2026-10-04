defmodule Arbiter.Tasks.Workspace.Changes.EnforceGuardrailAuthority do
  @moduledoc """
  Makes loosening `guardrails.*` and `agent.security` operator-only (G11,
  `docs/design/guardrail-profiles.md` §6.4, §7.1).

  Runs after `ValidateConfig` on every action that writes `config`. When the
  write moves the effective security posture or a guardrail looser
  (`Arbiter.Guardrails.Authority.config_loosenings/2`), the caller's authority
  must be `:operator`; a `:coordinator` (or anything else) is refused with an
  error on `:config` that names what it tried to loosen. A pure tightening, or a
  change that touches neither, passes for everyone.

  The authority is the Ash context key `:guardrail_authority`. It defaults to
  `:operator`: in-process callers (the dashboard, the Loop's operator-gated
  apply, boot-time migration) are trusted, and every untrusted entry point (the
  REST workspace controller, the MCP `workspace_config_*` tools) passes its own
  token's authority explicitly (`Arbiter.Guardrails.Authority.from_scope/1`).
  """

  use Ash.Resource.Change

  alias Arbiter.Guardrails.Authority
  alias Ash.Changeset

  @impl true
  def change(changeset, _opts, _context) do
    Changeset.before_action(changeset, fn changeset ->
      authority = Map.get(changeset.context || %{}, :guardrail_authority, :operator)

      with %{} = new <- Changeset.get_attribute(changeset, :config),
           true <- authority != :operator and not Enum.any?(changeset.errors) do
        old =
          case changeset.data do
            %{config: %{} = c} -> c
            _ -> %{}
          end

        case Authority.authorize(Authority.config_loosenings(old, new), authority) do
          :ok -> changeset
          {:error, message} -> Changeset.add_error(changeset, field: :config, message: message)
        end
      else
        _ -> changeset
      end
    end)
  end
end
