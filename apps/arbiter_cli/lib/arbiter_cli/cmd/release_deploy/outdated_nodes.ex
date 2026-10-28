defmodule ArbiterCli.Cmd.ReleaseDeploy.OutdatedNodes do
  @moduledoc """
  The post-deploy notice for nodes now behind the deployed version. A node whose agent is
  older than the server is `outdated` and gets no work, and a Helm-pinned cluster controller
  never moves by itself, so the deploy names each one with the command that upgrades it.
  Informational only: it never fails a deploy.
  """

  alias ArbiterCli.Client

  @type entry :: %{
          name: String.t(),
          version: String.t(),
          command: String.t()
        }

  @doc "Fetch the enrolled nodes and return those behind `tag`; `[]` when the lookup fails."
  @spec fetch(String.t()) :: [entry()]
  def fetch(tag) do
    case Client.get("/api/nodes") do
      {:ok, %{"nodes" => nodes}} when is_list(nodes) -> behind(nodes, tag)
      _ -> []
    end
  end

  @spec behind([map()], String.t()) :: [entry()]
  def behind(nodes, tag) do
    target = String.trim_leading(tag, "v")

    for n <- nodes,
        n["state"] != "revoked",
        n["self_upgrade"] != true,
        v = n["agent_version"],
        is_binary(v),
        older?(v, target) do
      %{
        name: n["name"],
        version: v,
        command: n["upgrade_command"] || "arb node upgrade #{n["name"]}"
      }
    end
  end

  @spec text([entry()], String.t()) :: String.t() | nil
  def text([], _tag), do: nil

  def text(entries, tag) do
    target = String.trim_leading(tag, "v")

    lines =
      Enum.map_join(entries, "\n", fn e ->
        "  #{e.name} is at v#{e.version} (server v#{target}); no work is placed on it until it " <>
          "is upgraded:\n    #{e.command}"
      end)

    "warning: #{length(entries)} node(s) are now behind this server:\n" <> lines
  end

  defp older?(a, b) do
    case {Version.parse(a), Version.parse(b)} do
      {{:ok, va}, {:ok, vb}} -> Version.compare(va, vb) == :lt
      _ -> false
    end
  end
end
