defmodule Arbiter.Nodes.JoinScript do
  @moduledoc """
  The node join script served at `GET /nodes/join`
  (`docs/design/remote-workers.md` §5.5), rendered server-side from config.

  The template (`join_script.sh.eex`) is a bash script that

    * refuses to run as root and **never uses sudo** (remediations are printed
      for the operator to run; the one fix it makes itself is
      `loginctl enable-linger` for the current user),
    * runs every prerequisite check **before** the join token is read, so a
      failing machine does not burn it (`ARB_JOIN_CHECK_ONLY=1` stops there),
    * reads the token from `ARB_JOIN_TOKEN_FILE`, `ARB_JOIN_TOKEN` or
      `/dev/tty` — never argv — and sends it only in the enroll request body,
    * trades it for a node credential, downloads the agent tarball with that
      credential (sha256 checked against the enroll response), unpacks it to
      `~/.arbiter-node/` and installs a user systemd unit (`ARB_ROLE=agent`).

  Every value interpolated into the template goes through `sh_quote/1`, so a
  hostile configuration value is one inert word. The whole script body lives in
  `main() { … }`, invoked on the last line, so a truncated pipe runs nothing.
  """

  require EEx

  @template Path.join(__DIR__, "join_script.sh.eex")
  @external_resource @template

  @proto 1
  @default_arch "x86_64"
  @default_min_podman_major 4
  @default_min_glibc "2.28"
  @default_min_disk_gb 10

  EEx.function_from_file(:defp, :eval_template, @template, [:assigns])

  @doc "The join-script protocol version the enroll endpoint speaks."
  @spec proto() :: pos_integer()
  def proto, do: @proto

  @doc """
  Render the script. Options: `:public_url` (required), `:arch`,
  `:min_podman_major`, `:min_glibc`, `:min_disk_gb`.
  """
  @spec render(keyword()) :: String.t()
  def render(opts) do
    eval_template(
      public_url: Keyword.fetch!(opts, :public_url),
      arch: Keyword.get(opts, :arch, @default_arch),
      min_podman_major: Keyword.get(opts, :min_podman_major, @default_min_podman_major),
      min_glibc: Keyword.get(opts, :min_glibc, @default_min_glibc),
      min_disk_gb: Keyword.get(opts, :min_disk_gb, @default_min_disk_gb),
      proto: @proto
    )
  end

  @doc """
  The command the operator pastes on the new node: it fetches the script and
  pipes it to bash. It carries **no secret** — the token is handed over
  separately and read from the terminal.
  """
  @spec one_liner(String.t()) :: String.t()
  def one_liner("https://" <> _ = url),
    do: "curl --proto '=https' --tlsv1.2 -fsSL #{url}/nodes/join | bash"

  def one_liner(url), do: "curl -fsSL #{url}/nodes/join | bash"

  @doc false
  @spec sh_quote(term()) :: String.t()
  def sh_quote(value) do
    "'" <> String.replace(to_string(value), "'", "'\\''") <> "'"
  end
end
