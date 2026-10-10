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
  """

  @seed ~S"""
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
  exec /opt/arbiter/bin/seed
  """

  @entry ~S"""
  set -eu
  set -a
  . /run/arb/env
  set +a
  rm -f /run/arb/env
  exec "$@"
  """

  @doc "The seed init container's script (gate first)."
  @spec seed() :: String.t()
  def seed, do: @seed

  @doc "The worker's entry wrapper: source and delete the secrets file, then `exec \"$@\"`."
  @spec entry() :: String.t()
  def entry, do: @entry

  @doc "Where the secrets file lives (a memory `emptyDir`); the seed container writes it."
  @spec env_file() :: String.t()
  def env_file, do: "/run/arb/env"
end
