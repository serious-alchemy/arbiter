defmodule Arbiter.Worker.Sandbox do
  @moduledoc """
  The OS sandbox a worker's CLI is spawned in (bd-btcdrf, P2;
  `docs/design/podman-worker-containers.md` §7.1).

  A behaviour with two implementations: `Arbiter.Worker.Jail` (bubblewrap) and
  `Arbiter.Worker.Container` (rootless podman, bd-bu4ye2). `module/1` resolves
  only `:bwrap`: the adapters only check that gate and would otherwise spawn
  unsandboxed under `backend: podman`. A provider that has a podman wrap point
  asks `module/2` by name instead, and today that is Claude (P7, bd-d2o3xb) and
  Codex (P8, bd-50d5j6), both through `Arbiter.Worker.ContainerSpawn`. Callers
  that jail a spawn go through this module with the resolved
  `Arbiter.Agents.SecurityPolicy`, which names the backend in `sandbox.backend`
  (`:bwrap` by default). They never call `Jail` for a spawn directly.

  ## Callbacks

    * `status/0` — `:ok` when this host can run the backend, else
      `{:error, reason}`.
    * `network_status/0` — the same for the backend's network-mode capability.
    * `wrap/2` — `{:ok, argv}`: the command wrapped to run inside the sandbox
      (executable first, one stable `--` boundary before the CLI), or
      `{:error, reason}`. See `Arbiter.Worker.Jail.wrap/2` for the options.
    * `teardown/1` — release whatever `wrap/2`'s run left behind (a named
      container, say). The bwrap jail dies with the process the port spawned, so
      its implementation is a no-op.

  ## Refusal, never an unjailed spawn

  `module/1` and `module/2` are the only places a backend atom becomes a
  module. A backend that is not wired for the provider asking (`:podman` for
  anything but Claude and Codex, per the agy decision) resolves to
  `{:error, {:sandbox_backend_unavailable, backend, message}}` and every
  function here passes that through. Callers must treat it as fatal for the
  spawn: it is **not** "the sandbox is unavailable on this host", which some
  modes degrade to running unjailed, but "the operator asked for a sandbox we
  cannot provide".
  """

  alias Arbiter.Agents.SecurityPolicy
  alias Arbiter.Worker.Container
  alias Arbiter.Worker.Jail

  @type backend :: SecurityPolicy.sandbox_backend()
  @type refusal :: {:sandbox_backend_unavailable, atom(), String.t()}

  @callback status() :: :ok | {:error, term()}
  @callback network_status() :: :ok | {:error, term()}
  @callback wrap(command :: [String.t()], opts :: keyword()) ::
              {:ok, [String.t()]} | {:error, term()}
  @callback teardown(run :: term()) :: :ok

  @doc """
  The implementation module for `backend` (or for `policy`'s
  `sandbox.backend`), or the refusal for a backend that has none.
  """
  @spec module(backend() | atom() | SecurityPolicy.t()) :: {:ok, module()} | {:error, refusal()}
  def module(%SecurityPolicy{} = policy),
    do: policy |> SecurityPolicy.sandbox_backend() |> module()

  def module(:bwrap), do: {:ok, Jail}

  def module(backend) when is_atom(backend) do
    {:error,
     {:sandbox_backend_unavailable, backend,
      "sandbox.backend #{backend} is not implemented yet; refusing to run this worker " <>
        "unsandboxed. Set sandbox.backend to bwrap or remove the override."}}
  end

  @doc """
  `module/1` for a spawn of `provider`: the same, except that `:podman`
  resolves to `Arbiter.Worker.Container` for the providers that have a wrap
  point for it (`:claude`, P7; `:codex`, P8). Every other provider under `:podman` is the
  refusal, so an adapter that only checks the gate can never spawn
  unsandboxed because another provider got a container.
  """
  @spec module(backend() | atom() | SecurityPolicy.t(), atom() | String.t()) ::
          {:ok, module()} | {:error, refusal()}
  def module(%SecurityPolicy{} = policy, provider),
    do: policy |> SecurityPolicy.sandbox_backend() |> module(provider)

  def module(:podman, provider) when provider in [:claude, "claude", :codex, "codex"],
    do: {:ok, Container}

  def module(:podman, provider) do
    {:error,
     {:sandbox_backend_unavailable, :podman,
      "sandbox.backend podman is wired for claude and codex only (P7, P8); #{provider} has no container " <>
        "wrap point yet, so it is refused rather than run unsandboxed. Dispatch it to " <>
        "claude, or set sandbox.backend to bwrap."}}
  end

  def module(backend, _provider), do: module(backend)

  @doc "`Jail.status/0` etc. for `policy`'s backend, or the refusal."
  @spec status(SecurityPolicy.t()) :: :ok | {:error, term()}
  def status(%SecurityPolicy{} = policy), do: with({:ok, mod} <- module(policy), do: mod.status())

  @spec network_status(SecurityPolicy.t()) :: :ok | {:error, term()}
  def network_status(%SecurityPolicy{} = policy),
    do: with({:ok, mod} <- module(policy), do: mod.network_status())

  @doc "Wrap `command` in `policy`'s sandbox backend."
  @spec wrap(SecurityPolicy.t(), [String.t()], keyword()) ::
          {:ok, [String.t()]} | {:error, term()}
  def wrap(%SecurityPolicy{} = policy, command, opts) when is_list(command) and is_list(opts),
    do: with({:ok, mod} <- module(policy), do: mod.wrap(command, opts))

  @doc """
  Tear down a run `wrap/3` set up under `policy`. A backend that was refused
  never started anything, so there is nothing to do.
  """
  @spec teardown(SecurityPolicy.t(), term()) :: :ok
  def teardown(%SecurityPolicy{} = policy, run) do
    case module(policy) do
      {:ok, mod} -> mod.teardown(run)
      {:error, _} -> :ok
    end
  end
end
