defmodule Arbiter.Worker.WorkerEnv do
  @moduledoc """
  Injects a workspace's user-defined env vars into worker subprocess
  environments, and surfaces the secret-flagged values that must be redacted
  from worker output.

  A workspace can define named env vars (an API token a test suite needs, a
  config value, …) via `Arbiter.Tasks.Workspace`'s `worker_env` argument. Every
  worker dispatched under that workspace gets them in its child environment.
  Per-key a value may be flagged `secret`, in which case it is masked in the UI
  and redacted (`Arbiter.Redaction`) anywhere worker output reaches a human.

  This module is the read side of that store, keyed by **task id** — the only
  workspace handle `Arbiter.Worker.ClaudeSession.env_pairs/3` has at spawn time.
  It mirrors the shape of the sibling env sources it sits beside in that
  pipeline (`Arbiter.Worker.ReleaseEnv.clean_pairs/0`,
  `Arbiter.Worker.DevServerEnv.pairs/1`).

  ## Override order

  Wired into `env_pairs/3` as:

      release_clean ++ dev_server_clean ++ worker_env ++ caller_env ++ [ARB_WORKER_BEAD_ID]

  User vars sit **after** the release/dev-server cleanups (so a user could
  intentionally override `DATABASE_PATH`, at their own risk) but **before** the
  caller-explicit `:env` — the agent's own auth (`ANTHROPIC_API_KEY`,
  `CLAUDE_CONFIG_DIR`, …) and the always-last `ARB_WORKER_BEAD_ID` guard always
  win, so a user env var can never break the agent's ability to authenticate or
  the task-id self-recursion guard.
  """

  require Logger

  alias Arbiter.Accounts.Census
  alias Arbiter.Accounts.Credentials
  alias Arbiter.Accounts.MissingCredentialError
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.ReviewGate

  @doc """
  Resolves both halves of the store for `task_id` from a **single** workspace
  load: `{pairs, secret_values}`.

  A spawn needs both — the pairs for the child's Port env, the secret values for
  the session's redaction list — and both derive from the same workspace, so
  `Arbiter.Worker.ClaudeSession.start/1` calls this once rather than paying two
  `Ash.get` round-trips per half.

  Returns `{[], []}` when `task_id` is not a non-empty string, the
  task/workspace can't be loaded, or no vars are configured — so the caller can
  splice the result in unconditionally.

  If the workspace resolves but its decrypted store is missing any key that
  `worker_env_meta` says should be configured — whether the store comes up
  entirely empty or just short some keys — that's a degradation rather than
  "nothing configured", and this logs a `Logger.warning` naming the task, the
  workspace, and the missing key(s), so the next occurrence is diagnosable
  from the log instead of a `/proc` inspection. A genuinely unconfigured
  workspace (empty `worker_env_meta`) never warns. If decryption itself raises
  (corrupt/undecryptable ciphertext), that is caught and logged too — this
  function never raises into a spawn.

  ## Provider credentials come from provider accounts (P3, bd-aiodva; P13, bd-9gqj8e)

  §5 row 17 splits this function: the workspace keeps answering for every
  **non-credential** var it defines, while the allowlisted provider-credential
  vars (`Arbiter.Accounts.Census.credential_keys/0` — `CLAUDE_CODE_OAUTH_TOKEN`,
  `OPENAI_API_KEY`, …) come from the workspace's provider accounts instead,
  across every provider it is linked to. The pair shape is unchanged, so the
  spawn env is unchanged (§5 row 20); only the source moves. Account secrets
  join the redaction list exactly as `secret`-flagged workspace vars do.

  The one case that *does* raise — the single exception to the paragraph above
  — is a credential the flip would silently drop: a var the blob still carries
  that no account supplies. That is
  `Arbiter.Accounts.MissingCredentialError`, and it is deliberate (acceptance
  3): a worker spawned with its credential quietly missing 401s minutes later
  and burns a run. A workspace with no provider credential configured at all
  is untouched and never raises.
  """
  @spec resolve(String.t() | nil, keyword()) :: {[{String.t(), String.t()}], [String.t()]}
  def resolve(task_id, opts \\ []) do
    case workspace_for(task_id) do
      %Workspace{} = ws ->
        workspace_pairs =
          try do
            ws |> Workspace.worker_env_map() |> Map.to_list()
          rescue
            error ->
              Logger.warning(
                "WorkerEnv: workspace #{ws.id} (#{ws.name}) has a worker env store that " <>
                  "raised while decrypting for task #{task_id}: #{Exception.format(:error, error)}"
              )

              []
          end

        workspace_secrets =
          if workspace_pairs == [] do
            []
          else
            Workspace.worker_env_secret_values(ws)
          end

        {pairs, secret_values} =
          apply_provider_accounts(ws, workspace_pairs, workspace_secrets, opts)

        warn_if_degraded(task_id, ws, pairs)
        {pairs, secret_values}

      nil ->
        {[], []}
    end
  end

  # Credential vars are swapped for the account's — the only source since the
  # P13 flip removed `:provider_accounts_enabled` (bd-9gqj8e).
  #
  # bd-7r0qrj: with `provider: "claude" | "codex" | "gemini" | nil` in `opts` the
  # *pairs* carry only that provider's accounts' credentials (`nil` = claude,
  # like `SpawnEnv`); without it, all of them (the redaction/inspection
  # callers). The redaction list and the dropped-credential guard always see
  # every account, so a filtered spawn still redacts the others and never
  # mistakes a filtered credential for a dropped one.
  defp apply_provider_accounts(%Workspace{} = ws, pairs, secrets, opts) do
    all_account_pairs = Credentials.workspace_pairs(ws.id)
    {credential_pairs, plain_pairs} = split_credential_pairs(pairs)

    ensure_no_credential_dropped!(ws, credential_pairs, all_account_pairs)

    {plain_pairs ++ spawn_account_pairs(ws, all_account_pairs, opts),
     drop_credential_secrets(secrets, credential_pairs) ++
       Enum.map(all_account_pairs, fn {_var, secret} -> secret end)}
  end

  defp spawn_account_pairs(%Workspace{} = ws, all_account_pairs, opts) do
    case Keyword.fetch(opts, :provider) do
      {:ok, provider} -> Credentials.workspace_pairs(ws.id, account_provider(provider))
      :error -> all_account_pairs
    end
  end

  # The adapter names the agy worker "gemini"; its accounts are `antigravity`.
  defp account_provider(nil), do: :claude

  defp account_provider(provider) when is_atom(provider),
    do: account_provider(Atom.to_string(provider))

  defp account_provider("gemini"), do: :antigravity
  defp account_provider("claude"), do: :claude
  defp account_provider("codex"), do: :codex
  # An unknown provider matches no account: fail closed rather than hand it all.
  defp account_provider(_other), do: :none

  defp split_credential_pairs(pairs) do
    credential_keys = Census.credential_keys()
    Enum.split_with(pairs, fn {name, _value} -> Map.has_key?(credential_keys, name) end)
  end

  # A value that only the blob's credential keys carried must not linger in
  # the redaction list: it is no longer in the child's environment.
  defp drop_credential_secrets(secrets, credential_pairs) do
    moved = MapSet.new(credential_pairs, fn {_name, value} -> value end)
    Enum.reject(secrets, &MapSet.member?(moved, &1))
  end

  # The flip is only safe while every credential the workspace already supplies
  # has an account to supply it. Anything the blob carries that no account
  # covers would vanish from the spawn env — loudly, not silently (§7.5).
  defp ensure_no_credential_dropped!(%Workspace{} = ws, credential_pairs, account_pairs) do
    supplied = MapSet.new(account_pairs, fn {name, _value} -> name end)

    case Enum.reject(Enum.map(credential_pairs, &elem(&1, 0)), &MapSet.member?(supplied, &1)) do
      [] ->
        :ok

      dropped ->
        raise MissingCredentialError, workspace_id: ws.id, env_vars: Enum.sort(dropped)
    end
  end

  # Only a workspace with configured keys (non-empty `worker_env_meta`) but a
  # decrypted store that's missing some of them is a degradation worth a
  # warning — a workspace with nothing configured at all producing `[]` is the
  # expected, silent case. Compares by name set so a *partial* degradation
  # (some keys resolved, others didn't) is caught too, not just a total miss.
  defp warn_if_degraded(task_id, %Workspace{} = ws, pairs) do
    configured = ws |> Workspace.worker_env_keys() |> MapSet.new(& &1.name)
    resolved = MapSet.new(pairs, fn {name, _value} -> name end)

    case MapSet.difference(configured, resolved) |> MapSet.to_list() do
      [] ->
        :ok

      missing ->
        Logger.warning(
          "WorkerEnv: workspace #{ws.id} (#{ws.name}) has configured worker env key(s) " <>
            "#{Enum.join(missing, ", ")} that worker_env_map/1 did not decrypt for task " <>
            "#{task_id} — encrypted_worker_env may be NULL, unloaded, or empty"
        )
    end
  end

  @doc """
  Returns the workspace's user-defined env vars for `task_id` as decrypted
  `{name, value}` pairs, ready to append to a worker's Port env.

  Prefer `resolve/1` when you also need the secret values — this is the
  single-half convenience wrapper.
  """
  @spec pairs(String.t() | nil) :: [{String.t(), String.t()}]
  def pairs(task_id), do: task_id |> resolve() |> elem(0)

  @doc """
  Returns the values of the workspace's **secret-flagged** worker env vars for
  `task_id` — the strings `Arbiter.Redaction` must scrub from worker output.

  Prefer `resolve/1` when you also need the pairs.
  """
  @spec secret_values(String.t() | nil) :: [String.t()]
  def secret_values(task_id), do: task_id |> resolve() |> elem(1)

  @doc """
  Resolve the workspace backing a task id, or `nil` on any miss. Best-effort:
  a spawn must never crash because the env store couldn't be read.

  ReviewGate mints synthetic task ids for spawned reviewer/implementer/
  verifier workers (`<base>#review`, `#r<N>`, `#impl<N>`, `#v<N>`, `#t<N>`,
  or a chain of these) that are never real `Issue` ids on their own — so
  this normalizes back to the authoring task id via `ReviewGate.base_task_id/1`
  before looking it up. Without that, every synthetic-id worker would miss
  here and silently get no env vars and no redaction list.

  Public because `Arbiter.Worker.ClaudeSession` needs the same workspace to
  hand `Arbiter.Agents.Claude.ConfigDir` on the spawn path that builds its own
  env (bd-bw3466).
  """
  @spec workspace_for(String.t() | nil) :: Workspace.t() | nil
  def workspace_for(task_id) when is_binary(task_id) and task_id != "" do
    base = ReviewGate.base_task_id(task_id)

    case Ash.get(Issue, base) do
      {:ok, %Issue{workspace_id: ws_id}} when is_binary(ws_id) ->
        case Ash.get(Workspace, ws_id) do
          {:ok, %Workspace{} = ws} ->
            ws

          {:error, error} ->
            Logger.warning(
              "WorkerEnv: Issue #{base} (from task #{task_id}) has workspace_id #{ws_id} " <>
                "but its workspace failed to load: #{inspect(error)}"
            )

            nil
        end

      {:ok, %Issue{}} ->
        Logger.debug("WorkerEnv: Issue #{base} (from task #{task_id}) has no workspace_id")

        nil

      {:error, error} ->
        Logger.debug(
          "WorkerEnv: could not load Issue #{base} (from task #{task_id}): #{inspect(error)}"
        )

        nil
    end
  end

  def workspace_for(_), do: nil
end
