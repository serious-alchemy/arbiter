defmodule Arbiter.NodeAgent.K8s.PodScripts do
  @moduledoc """
  The two shell scripts the pod builder renders into `command:` so the pod needs
  no image change (`docs/design/remote-workers.md` §10.1, §8.2).

  K4 pins the *contract* the builder depends on; K7 owns the runtime and may grow
  these bodies (the netpol gate is already here because it is a security
  property: nothing untrusted may start before the network policy is enforced).

    * `seed/0` runs as the `seed` init container. **Step 0 is the netpol gate**
      (K1-A3): a fresh pod is unfiltered for a fraction of a second until the CNI
      programs its chain, so seed loops on a connect to `$ARB_GATE_ADDR` (an
      address no worker may reach) until it is refused, and exits 70 after
      `$ARB_GATE_TIMEOUT_S` seconds, which the controller reports as
      `refuse{netpol_unenforced}`. Then it hands over to `/opt/arbiter/bin/seed`
      (K7).
    * `entry/0` is the worker's entry wrapper: it sources the per-run secrets
      file from the memory `emptyDir`, **deletes it**, and `exec`s the command, so
      the values exist only in the worker process's environment, as under podman
      (`Container.secrets_wrapper/1`). The command arrives as separate argv
      words after `$0`, never interpolated into the script text.

  ## The image's scripts (K7)

  `bin/0` is the two programs the base image carries under `/opt/arbiter/bin`
  (`Arbiter.Worker.Image` bakes them into the base layer, so a change to either
  rebuilds the base once): `seed`, the init container's second stage, and
  `snapshotter`, the native sidecar. They live in `priv/k8s_pod/` as plain files so
  `shellcheck` and the podman harness can run them as the pod does.
  """

  @bin_dir Path.expand("../../../../priv/k8s_pod", __DIR__)
  @bin_names ~w(seed snapshotter)
  for name <- @bin_names, do: @external_resource(Path.join(@bin_dir, name))
  @bin Map.new(@bin_names, &{&1, File.read!(Path.join(@bin_dir, &1))})

  @gate ~S"""
  set -eu
  # step 0: the netpol gate (K1-A3). Refused means the policy is programmed.
  gate_host=${ARB_GATE_ADDR%:*}
  gate_port=${ARB_GATE_ADDR##*:}
  tries=0
  max=$(( ${ARB_GATE_TIMEOUT_S:-30} * 10 ))
  while socat -T1 /dev/null "TCP:${gate_host}:${gate_port},connect-timeout=1" >/dev/null 2>&1; do
    tries=$((tries + 1))
    if [ "$tries" -ge "$max" ]; then
      echo "arbiter seed: the network policy is not enforced (netpol_unenforced)" >&2
      exit 70
    fi
    sleep 0.1
  done
  """

  @seed @gate <> "exec /opt/arbiter/bin/seed\n"

  @entry ~S"""
  set -eu
  set -a
  # shellcheck source=/dev/null
  . /run/arb/env
  set +a
  rm -f /run/arb/env
  exec "$@"
  """

  @doc "The seed init container's script (gate first)."
  @spec seed() :: String.t()
  def seed, do: @seed

  @doc """
  Step 0 alone: the netpol gate, exiting 70 when the gate address stays reachable.
  The readiness canary (`Arbiter.NodeAgent.K8s.Canary`) runs it as its `seed`
  container, so its probes measure the steady state, not the start-up window.
  """
  @spec gate() :: String.t()
  def gate, do: @gate

  @doc "The worker's entry wrapper: source and delete the secrets file, then `exec \"$@\"`."
  @spec entry() :: String.t()
  def entry, do: @entry

  @doc "The programs the base image carries under `/opt/arbiter/bin`, by file name."
  @spec bin() :: %{String.t() => String.t()}
  def bin, do: @bin

  @doc """
  The `RUN` instruction that installs `bin/0` as `/opt/arbiter/bin/<name>` (mode
  0755, owned by root, so the uid-10001 worker cannot rewrite them).

  The files travel inside the Containerfile text, base64 in 76-column pieces joined by backslash-newline (which the Containerfile parser removes),
  because a base build runs from an empty context (a repo cannot `COPY` anything
  into the base) and the plan a node agent builds from carries only text. No
  heredoc syntax, so it builds on any buildah.
  """
  @spec image_install() :: String.t()
  def image_install do
    steps =
      for {name, text} <- Enum.sort(@bin) do
        b64 =
          text
          |> Base.encode64()
          |> String.graphemes()
          |> Enum.chunk_every(76)
          |> Enum.map_join("\\\n", &Enum.join/1)

        "printf '%s' '#{b64}' | base64 -d > /opt/arbiter/bin/#{name}" <>
          " && chmod 0755 /opt/arbiter/bin/#{name}"
      end

    "RUN mkdir -p /opt/arbiter/bin \\\n && " <> Enum.join(steps, " \\\n && ")
  end

  @doc "Where the secrets file lives (a memory `emptyDir`); the seed container writes it."
  @spec env_file() :: String.t()
  def env_file, do: "/run/arb/env"
end
