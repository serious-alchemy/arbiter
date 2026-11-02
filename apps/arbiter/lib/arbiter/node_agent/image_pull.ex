defmodule Arbiter.NodeAgent.ImagePull do
  @moduledoc """
  The pull clause of a machine node's image step (SI4,
  `docs/design/remote-workers.md` §21.2.1, §21.4): a run whose spec names a
  digest-pinned `image.ref` runs the image the primary published, never one the
  node built.

  1. **Present?** `podman image exists <ref>`: a digest reference, so presence is
     exact, and a node that holds the digest runs without the registry.
  2. **Pull** otherwise: `podman pull --quiet [--authfile <file>] [--tls-verify=false]
     <ref>`. The spec's `pull_auth` (`Arbiter.NodeAgent.PullAuth`) is written as a
     containers auth file into the run's secrets directory on the tmpfs
     (`Arbiter.NodeAgent.Secrets.write_authfile/3`: refused, and nothing written,
     without a tmpfs) and removed when the pull ends, however it ends. podman is
     never asked to `login`, which would persist it, and keeps no credential with
     the image. With no `pull_auth` the pull is anonymous (a registry the operator
     marked `public_ok`). `--tls-verify=false` only for `image.insecure`. podman's
     output is scrubbed of the credential before it goes into a refusal.
  3. **Check** one `podman image inspect <ref>` of its labels, on a warm node too:
     `arbiter.runtime-contract` must be a version in `runtime_contracts/0` (the
     agent advertises them as `caps.runtime_contracts`), `arbiter.cli-set` must be
     the spec's `image.cli_set`, and the run's `image.provider` must be in
     `arbiter.cli-providers` with its `arbiter.cli.<provider>.version` and `.sha256`.

  Errors are coded as `Arbiter.NodeAgent.Run`'s refusals: `{:image_unavailable,
  {:pull_failed, status, output}}`, `{:image_unavailable, {:contract_mismatch,
  label, found}}`, `{:image_unavailable, {:inspect_failed, detail}}`, and
  `{:unschedulable, reason}` when there is nowhere safe to put the credential.

  A pull is bounded generously (`:pull_timeout_ms`, 30 minutes): the primary's own
  prepare bound for a pull is shorter (`Arbiter.Nodes.Session`), and a pull that
  outlives the refusal keeps going so the node's next run finds the image.

  Options: `:podman`, `:runner` (the `Arbiter.Worker.Container.cmd/4` seam),
  `:runtime_dir`, `:require_tmpfs`, `:mountinfo` (`Secrets`'), `:pull_timeout_ms`.
  """

  alias Arbiter.NodeAgent.{PullAuth, RunSpec, Secrets}
  alias Arbiter.Worker.Container

  @runtime_contracts [1]
  @pull_timeout_ms 30 * 60_000
  @quick_timeout_ms 60_000
  @tail_bytes 2_000

  @doc "The `arbiter.runtime-contract` versions this agent runs (`caps.runtime_contracts`)."
  @spec runtime_contracts() :: [pos_integer()]
  def runtime_contracts, do: @runtime_contracts

  @doc "Make `spec.image.ref` present on this node and check its labels."
  @spec ensure(RunSpec.t(), keyword()) :: :ok | {:error, {atom(), term()}}
  def ensure(%RunSpec{image: %{ref: ref} = image} = spec, opts) when is_binary(ref) do
    with :ok <- present_or_pull(ref, image, spec, opts),
         {:ok, labels} <- labels(ref, opts) do
      check(labels, image)
    end
  end

  # -- present, or pulled -------------------------------------------------------------

  defp present_or_pull(ref, image, spec, opts) do
    case podman(opts, ["image", "exists", ref], @quick_timeout_ms) do
      {_, 0} -> :ok
      _ -> pull(ref, image, spec, opts)
    end
  end

  defp pull(ref, image, %RunSpec{pull_auth: nil}, opts), do: run_pull(ref, image, [], nil, opts)

  defp pull(ref, image, %RunSpec{pull_auth: %PullAuth{} = auth, run: run}, opts) do
    secrets_opts = Keyword.take(opts, [:runtime_dir, :require_tmpfs, :mountinfo])

    case Secrets.write_authfile(run, PullAuth.authfile_json(auth), secrets_opts) do
      {:ok, file} ->
        try do
          run_pull(ref, image, ["--authfile", file], auth, opts)
        after
          File.rm(file)
        end

      {:error, reason} ->
        {:error, {:unschedulable, reason}}
    end
  end

  defp run_pull(ref, image, auth_flags, auth, opts) do
    tls = if Map.get(image, :insecure?) == true, do: ["--tls-verify=false"], else: []
    timeout = Keyword.get(opts, :pull_timeout_ms, @pull_timeout_ms)

    case podman(opts, ["pull", "--quiet"] ++ auth_flags ++ tls ++ [ref], timeout) do
      {_, 0} -> :ok
      {out, status} -> {:error, {:image_unavailable, {:pull_failed, status, scrub(out, auth)}}}
    end
  end

  defp scrub(out, auth) do
    out = PullAuth.redact(out, auth)
    size = byte_size(out)
    if size > @tail_bytes, do: binary_part(out, size - @tail_bytes, @tail_bytes), else: out
  end

  # -- labels ---------------------------------------------------------------------------

  # stderr stays out of the JSON: podman prints warnings there.
  defp labels(ref, opts) do
    case podman(opts, ["image", "inspect", ref], @quick_timeout_ms, stderr_to_stdout: false) do
      {out, 0} ->
        case Jason.decode(out) do
          {:ok, [%{} = body | _]} ->
            {:ok, labels_of(body["Labels"] || get_in(body, ["Config", "Labels"]))}

          _ ->
            {:error, {:image_unavailable, {:inspect_failed, :unparsable}}}
        end

      {out, status} ->
        {:error, {:image_unavailable, {:inspect_failed, {status, scrub(out, nil)}}}}
    end
  end

  defp labels_of(%{} = labels), do: labels
  defp labels_of(_), do: %{}

  defp check(labels, image) do
    with :ok <- contract(labels),
         :ok <- cli_set(labels, Map.get(image, :cli_set)) do
      provider(labels, Map.get(image, :provider))
    end
  end

  @contract "arbiter.runtime-contract"
  @cli_set "arbiter.cli-set"

  defp contract(labels) do
    found = labels[@contract]

    with value when is_binary(value) <- found,
         {version, ""} <- Integer.parse(value),
         true <- version in @runtime_contracts do
      :ok
    else
      _ -> mismatch(@contract, found)
    end
  end

  defp cli_set(labels, wanted) when is_binary(wanted) do
    if labels[@cli_set] == wanted, do: :ok, else: mismatch(@cli_set, labels[@cli_set])
  end

  defp cli_set(labels, _none), do: mismatch(@cli_set, labels[@cli_set])

  defp provider(labels, provider) when is_binary(provider) do
    prefix = "arbiter.cli." <> provider
    providers = String.split(labels["arbiter.cli-providers"] || "", ",", trim: true)

    if provider in providers and present?(labels[prefix <> ".version"]) and
         present?(labels[prefix <> ".sha256"]),
       do: :ok,
       else: mismatch(prefix, labels["arbiter.cli-providers"])
  end

  defp provider(labels, _none),
    do: mismatch("arbiter.cli.<provider>", labels["arbiter.cli-providers"])

  defp present?(value), do: is_binary(value) and value != ""

  defp mismatch(item, found),
    do: {:error, {:image_unavailable, {:contract_mismatch, item, found}}}

  # -- podman -----------------------------------------------------------------------------

  defp podman(opts, args, timeout, extra \\ []) do
    Container.cmd(
      Keyword.take(opts, [:runner]),
      Keyword.get(opts, :podman) || System.find_executable("podman") || "podman",
      args,
      [timeout: timeout] ++ extra
    )
  end
end
