defmodule ArbiterWeb.StubPodman do
  @moduledoc """
  The node-agent tests' stand-in `podman` (see `Arbiter.NodeAgent.StubPodman` in
  `apps/arbiter`, whose script this installs): a real child process for the
  agent's real `Port` and exit path, with what it was asked to do recorded under
  the directory it is installed in.
  """

  @script_path Path.expand("../../../../arbiter/test/support/node_agent/stub_podman.sh", __DIR__)
  @external_resource @script_path
  @script File.read!(@script_path)

  @doc "Create the stub under `dir` and point `STUB_PODMAN_DIR` at it; returns the script path."
  @spec install(Path.t()) :: Path.t()
  def install(dir) do
    File.mkdir_p!(dir)
    path = Path.join(dir, "podman")
    File.write!(path, @script)
    File.chmod!(path, 0o755)
    System.put_env("STUB_PODMAN_DIR", dir)
    path
  end

  @spec write_mode(Path.t(), String.t()) :: :ok
  def write_mode(dir, mode), do: File.write!(Path.join(dir, "mode"), mode)
end
