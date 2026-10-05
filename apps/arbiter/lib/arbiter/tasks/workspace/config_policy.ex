defmodule Arbiter.Tasks.Workspace.ConfigPolicy do
  @moduledoc """
  Behaviour for a cross-workspace policy over `Workspace.config` changes.

  `Arbiter.Tasks.Workspace.Changes.ValidateConfig` calls the configured policy
  (`config :arbiter, :workspace_config_policy, Mod`) after its own shape
  validation passes, on every create/update that carries a config map. The
  default, `Arbiter.Tasks.Workspace.ConfigPolicy.Default`, allows everything.

  A policy can reject a change (`{:error, message}`) or annotate / clamp it by
  returning a replacement config (`{:ok, config}`).
  """

  @doc """
  Check a validated config. `context` has `:action` (`:create` | `:update`)
  and `:workspace` (the existing record, or `nil` on create).
  """
  @callback check(config :: map(), context :: %{action: atom(), workspace: struct() | nil}) ::
              :ok | {:ok, map()} | {:error, String.t()}
end
