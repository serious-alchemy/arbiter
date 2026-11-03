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

  if [ "${ARB_EVENTS:-}" != 1 ]; then
    exec "$@"
  fi

  # The event feed (bd-1nl506). The agent's stdout and stderr are teed to an NDJSON file
  # and shipped to the controller in byte-offset chunks (POST /events), which the primary
  # reads instead of the kubelet's log; the log keeps the same bytes for a human. The
  # command keeps its argv and its exit status; SIGTERM/SIGINT are forwarded to it.
  umask 077
  events_dir=${ARB_EVENTS_DIR:-${HOME:-/tmp}/.arb-events}
  run_dir=${ARB_RUN_DIR:-/run/arb}
  ca_file=${ARB_CA_FILE:-/etc/arb/ca/ca.crt}
  chunk=${ARB_EVENTS_CHUNK:-262144}
  addr=${ARB_BRIDGE_ADDR:-}
  case $addr in
    *:*) addr="[$addr]" ;;
  esac
  channel=${ARB_EVENTS_URL:-https://${addr}:${ARB_CHANNEL_PORT:-9444}/events}
  mkdir -p "$events_dir"
  events=$events_dir/events.ndjson
  fifo=$events_dir/events.fifo
  part=$events_dir/part
  reply=$events_dir/reply
  rm -f "$events" "$fifo"
  : >"$events"
  mkfifo "$fifo"

  tee -a "$events" <"$fifo" &
  tee_pid=$!
  "$@" <&0 >"$fifo" 2>&1 &
  cmd_pid=$!
  trap 'kill -TERM "$cmd_pid" 2>/dev/null || true' TERM INT

  # Bytes of the file the controller holds. It is the controller's word (`next` in the
  # reply) that moves it, in either direction: a restarted controller asks for a rewind.
  sent=0
  code=000

  post() {
    tail -c +$((sent + 1)) "$events" | head -c "$chunk" >"$part"
    code=$(curl -sS --cacert "$ca_file" \
      --cert "$run_dir/tls/control.crt" --key "$run_dir/tls/control.key" \
      --max-time 30 -X POST -H "x-arb-offset: $sent" -H "x-arb-final: $1" \
      --data-binary @"$part" -o "$reply" -w '%{http_code}' "$channel" 2>/dev/null) || code=000
    case $code in
      200 | 409)
        next=$(sed -n 's/.*"next" *: *\([0-9][0-9]*\).*/\1/p' "$reply" 2>/dev/null | head -n 1)
        if [ -n "$next" ]; then
          sent=$next
        elif [ "$code" = 200 ]; then
          sent=$((sent + $(wc -c <"$part")))
        fi
        return 0
        ;;
    esac
    return 1
  }

  # While the command runs: ship whatever has been written, poll for more.
  while kill -0 "$cmd_pid" 2>/dev/null; do
    size=$(wc -c <"$events")
    if [ "$sent" -lt "$size" ]; then
      if post 0; then continue; fi
      sleep 2
    fi
    sleep 0.5
  done

  status=0
  wait "$cmd_pid" || status=$?

  # The tee ends with the command's last write; a background process of the command that
  # still holds the pipe open does not get to hold the run back.
  waited=0
  while kill -0 "$tee_pid" 2>/dev/null && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done

  # The rest, and then the end of the feed: a chunk marked final. A feed that is cut short
  # (this loop gives up, or the container is killed) is the controller's to notice: it
  # drops a last line with no newline and reports the stream as truncated.
  tries=0
  rounds=0
  while [ "$tries" -lt "${ARB_EVENTS_FINAL_TRIES:-30}" ] && [ "$rounds" -lt 100000 ]; do
    rounds=$((rounds + 1))
    size=$(wc -c <"$events")
    final=0
    if [ "$sent" -ge "$size" ]; then final=1; fi
    if post "$final"; then
      if [ "$final" = 1 ] && [ "$code" = 200 ]; then break; fi
    else
      tries=$((tries + 1))
      sleep 1
    fi
  done

  exit "$status"
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
