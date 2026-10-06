defmodule Arbiter.NodeAgent.StubPodman do
  @moduledoc """
  A stand-in `podman` for the node-agent tests (RW9): a shell script that
  records what it was asked to do under `<dir>/` and behaves as `<dir>/mode`
  says, so the agent's real argv, the real `Port` and the real exit path run
  without podman.

  What it records (the evidence the secrets tests read):

    * `run.argv` — one argument per line;
    * `run.env` — the environment the client was started with (`env -0`-free
      `NAME=value` lines);
    * `graph/config.json` — what real podman would persist: every `-e NAME`
      resolved to its value, and every `-e NAME=value` literal. A secret that
      travelled as `-e` would show here; the agent's design puts none there;
    * `secrets.seen` — the body of whatever file was bind-mounted at
      `/run/arbiter/secrets.env`, read while the "container" ran;
    * `calls` — every subcommand (`run`, `inspect`, `rm`, `kill`, …).

  Modes (`write_mode/2`): `lines` (print `line-1`…`line-N`, exit 0), `oom` (exit 137,
  `OOMKilled=true`), `hang` (print one line, then wait until removed) and
  `big` (print `STUB_BYTES` bytes, exit 0).
  """

  @script ~S"""
  #!/bin/sh
  D="${STUB_PODMAN_DIR:?}"
  sub="$1"
  echo "$sub $*" >> "$D/calls"
  case "$sub" in
    run)
      printf '%s\n' "$@" > "$D/run.argv"
      env > "$D/run.env"
      mkdir -p "$D/graph"
      : > "$D/graph/config.json"
      prev=""
      for a in "$@"; do
        case "$prev" in
          -e)
            case "$a" in
              *=*) echo "$a" >> "$D/graph/config.json" ;;
              *) eval "echo \"$a=\${$a}\"" >> "$D/graph/config.json" ;;
            esac ;;
          -v)
            case "$a" in
              *:/run/arbiter/secrets.env:*) cat "${a%%:*}" > "$D/secrets.seen" ;;
            esac ;;
        esac
        prev="$a"
      done
      mode=$(cat "$D/mode" 2>/dev/null || echo lines)
      echo $$ > "$D/run.pid"
      case "$mode" in
        lines)
          n=$(cat "$D/lines" 2>/dev/null || echo 3)
          i=1
          while [ "$i" -le "$n" ]; do echo "line-$i"; i=$((i+1)); done
          exit 0 ;;
        oom) echo "line-1"; echo true > "$D/oom"; exit 137 ;;
        hang) echo "line-1"; while [ ! -e "$D/removed" ]; do sleep 0.05; done; exit 137 ;;
        big) head -c "${STUB_BYTES:-1000000}" /dev/zero | tr '\0' 'x'; echo; exit 0 ;;
      esac ;;
    inspect) cat "$D/oom" 2>/dev/null || echo false ;;
    rm) : > "$D/removed"; exit 0 ;;
    kill) exit 0 ;;
    image) exit 0 ;;
    *) exit 0 ;;
  esac
  """

  @doc "Create the stub under `dir`; returns the script path."
  @spec install(Path.t()) :: Path.t()
  def install(dir) do
    File.mkdir_p!(dir)
    path = Path.join(dir, "podman")
    File.write!(path, String.replace(@script, ~r/^  /m, ""))
    File.chmod!(path, 0o755)
    System.put_env("STUB_PODMAN_DIR", dir)
    path
  end

  @spec write_mode(Path.t(), String.t()) :: :ok
  def write_mode(dir, mode), do: File.write!(Path.join(dir, "mode"), mode)

  @doc "Everything the stub recorded, as one string (for marker scans)."
  @spec recorded(Path.t()) :: String.t()
  def recorded(dir) do
    dir
    |> Path.join("**")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.reject(&(Path.basename(&1) == "podman"))
    |> Enum.map_join("\n", &File.read!/1)
  end
end
