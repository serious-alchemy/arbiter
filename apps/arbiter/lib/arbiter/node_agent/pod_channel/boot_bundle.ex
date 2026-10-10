defmodule Arbiter.NodeAgent.PodChannel.BootBundle do
  @moduledoc """
  The response to a redeemed `/boot` nonce (`docs/design/remote-workers.md`
  §16 K§10.1, K§12): a tar the pod's `seed` init container unpacks into a
  memory `emptyDir`. It is the only way the run's secrets reach the pod, and it
  is built in memory from the validated `Arbiter.NodeAgent.RunSpec`, so they are
  never a Kubernetes object, never in the pod spec and never on the
  controller's disk.

  | entry | content |
  |---|---|
  | `tls/<bridge>.crt`, `.key` | the run's leaf for each bridge in its spec (`CN` run, `OU` bridge) |
  | `tls/control.crt`, `.key` | the leaf for `:9444` (seed, checkpoint, transcripts, commands) |
  | `secrets.env` | the spec's `secrets` as `export NAME='value'` lines (mode `0600`), as `Arbiter.NodeAgent.Secrets.render/1` writes them |
  | `worktree/<path>` | the spec's worktree seed files (`.mcp.json` with the worker-tier bearer, `.claude/skills/…`) |
  | `config_dir/<name>` | the spec's config-dir files (`settings.json`, `CLAUDE.md`) |
  | `prompt/<n>` | the spec's prompt mounts, in order |
  | `manifest.json` | the run id, checkout settings, bridge names and where each prompt goes. **No secret.** |
  """

  alias Arbiter.NodeAgent.PodChannel.BootBundle.Tar
  alias Arbiter.NodeAgent.PodChannel.Cert
  alias Arbiter.NodeAgent.{RunSpec, Secrets}

  @doc "The tar for `spec`, with `leaves` (`%{ou => cert}`) as minted for the run."
  @spec build(RunSpec.t(), %{String.t() => Cert.t()}) :: binary()
  def build(%RunSpec{} = spec, leaves) do
    prompts = for %{kind: "prompt"} = m <- spec.mounts, do: m

    entries =
      [{"manifest.json", Jason.encode!(manifest(spec, prompts)), 0o644}] ++
        tls(leaves) ++ secrets(spec.secrets) ++ seed_files(spec.mounts) ++ prompts(prompts)

    Tar.encode(entries)
  end

  defp manifest(spec, prompts) do
    %{
      "run" => spec.run,
      "checkout" => checkout(spec.checkout),
      "bridges" => Enum.map(spec.bridges, & &1.name),
      "prompts" =>
        prompts
        |> Enum.with_index()
        |> Enum.map(fn {m, i} -> %{"file" => "prompt/#{i}", "path" => m.path} end)
    }
  end

  defp checkout(nil), do: nil

  defp checkout(%{branch: branch, base: base, interval_ms: ms}),
    do: %{"branch" => branch, "base" => base, "interval_s" => div(ms, 1000)}

  defp tls(leaves) do
    leaves
    |> Enum.sort()
    |> Enum.flat_map(fn {name, cert} ->
      [
        {"tls/#{name}.crt", Cert.pem_cert(cert.der), 0o644},
        {"tls/#{name}.key", Cert.pem_key(cert.key), 0o600}
      ]
    end)
  end

  defp secrets(secrets) when map_size(secrets) == 0, do: []
  defp secrets(secrets), do: [{"secrets.env", Secrets.render(secrets), 0o600}]

  defp seed_files(mounts) do
    for %{kind: kind, files: files} <- mounts,
        kind in ["worktree", "config_dir"],
        {name, bytes} <- Enum.sort(files),
        do: {"#{kind}/#{name}", bytes, 0o600}
  end

  defp prompts(prompts) do
    prompts |> Enum.with_index() |> Enum.map(fn {m, i} -> {"prompt/#{i}", m.content, 0o600} end)
  end
end
