defmodule Arbiter.Guardrails.Permissions do
  @moduledoc """
  The ticket-declared permission vocabulary and who may set it
  (`docs/design/guardrail-profiles.md` §5.1–5.3). Pure: no DB, no config reads.

  A permission is an **action** (`network:<host>[:<port>]`, `tracker_write`,
  `secrets:<name>`, `prod_read`, `prod_ssh`) or a **data class** (`phi_data`).
  A trailing `?` after the kind marks an action optional (§5.7), e.g.
  `network?:status.example.com`; prod permissions and data classes are never
  optional.

  Canonical form (what `issues.permissions` stores): lower-case host, explicit
  port (443 when omitted), sorted, de-duplicated — see `normalize/1`.

  ## Authority

  Reuses `Arbiter.Guardrails.Authority`'s atoms: `:operator`, `:coordinator`,
  `:restricted` (worker, refine, no token). `plan/4` turns an old and a new
  list into the `permission_events` a change implies, or refuses:

    * a restricted caller sets nothing (workers never set permissions, §5.3 (5));
    * a coordinator declaring a permission whose `grant_by` is `operator`
      records `requested`, not `declared`;
    * removing an action tightens (any coordinator), removing a data class
      loosens (operator only, §5.3 (6)).

  `grant_by/2` reads the workspace `guardrails.bindings` block; `block` is the
  string-keyed block from `Arbiter.Guardrails.Config.block/1`.
  """

  @type authority :: Arbiter.Guardrails.Authority.authority()
  @type kind :: :network | :tracker_write | :secrets | :prod_read | :prod_ssh | :phi_data
  @type parsed :: %{
          kind: kind(),
          optional?: boolean(),
          canonical: String.t()
        }
  @type planned :: %{permission: String.t(), event: :declared | :requested | :revoked}

  @data_classes [:phi_data]
  @never_optional [:prod_read, :prod_ssh, :phi_data]
  @host_re ~r/\A[a-z0-9]([a-z0-9.-]*[a-z0-9])?\z/
  @name_re ~r/\A[A-Za-z0-9_.-]+\z/

  @doc "The kinds in the vocabulary."
  @spec kinds() :: [kind()]
  def kinds, do: [:network, :tracker_write, :secrets, :prod_read, :prod_ssh, :phi_data]

  @doc "Parse one permission string into its canonical form, or an error message."
  @spec parse(term()) :: {:ok, parsed()} | {:error, String.t()}
  def parse(raw) when is_binary(raw) do
    raw = String.trim(raw)

    case Regex.run(~r/\A([a-z_]+)(\?)?(?::(.*))?\z/s, raw) do
      [_, kind, opt, arg] -> build(kind, opt == "?", arg, raw)
      [_, kind, opt] -> build(kind, opt == "?", nil, raw)
      [_, kind] -> build(kind, false, nil, raw)
      _ -> {:error, unknown(raw)}
    end
  end

  def parse(other), do: {:error, "permission must be a string, got #{inspect(other)}"}

  defp build(kind, optional?, arg, raw) do
    case kind_atom(kind) do
      nil ->
        {:error, unknown(raw)}

      kind when optional? and kind in @never_optional ->
        {:error, "#{kind} cannot be optional (prod permissions and data classes never are)"}

      kind ->
        with {:ok, tail} <- canonical_arg(kind, arg, raw) do
          {:ok, %{kind: kind, optional?: optional?, canonical: render(kind, optional?, tail)}}
        end
    end
  end

  defp kind_atom(name) do
    Enum.find(kinds(), &(Atom.to_string(&1) == name))
  end

  defp canonical_arg(:network, arg, raw) when is_binary(arg), do: host_port(arg, raw)
  defp canonical_arg(:network, nil, raw), do: {:error, "#{raw}: network needs a host"}

  defp canonical_arg(:secrets, arg, raw) when is_binary(arg) do
    if Regex.match?(@name_re, arg), do: {:ok, arg}, else: {:error, "#{raw}: bad secret name"}
  end

  defp canonical_arg(:secrets, nil, raw), do: {:error, "#{raw}: secrets needs a name"}
  defp canonical_arg(_kind, nil, _raw), do: {:ok, nil}
  defp canonical_arg(_kind, _arg, raw), do: {:error, "#{raw}: takes no argument"}

  defp host_port(arg, raw) do
    {host, port} =
      case String.split(arg, ":", parts: 2) do
        [h, p] -> {h, p}
        [h] -> {h, "443"}
      end

    host = String.downcase(host)

    with true <- Regex.match?(@host_re, host),
         {n, ""} when n in 1..65_535 <- Integer.parse(port) do
      {:ok, "#{host}:#{n}"}
    else
      _ -> {:error, "#{raw}: not a valid host[:port]"}
    end
  end

  defp render(kind, optional?, tail) do
    [Atom.to_string(kind), if(optional?, do: "?"), tail && ":" <> tail]
    |> Enum.reject(&is_nil/1)
    |> Enum.join()
  end

  defp unknown(raw) do
    "unknown permission #{inspect(raw)}; expected network:<host>[:<port>], tracker_write, " <>
      "secrets:<name>, prod_read, prod_ssh or phi_data"
  end

  @doc "Canonical, sorted, de-duplicated; `nil` is `[]`."
  @spec normalize(term()) :: {:ok, [String.t()]} | {:error, String.t()}
  def normalize(nil), do: {:ok, []}

  def normalize(list) when is_list(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn raw, {:ok, acc} ->
      case parse(raw) do
        {:ok, %{canonical: c}} -> {:cont, {:ok, [c | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, acc |> Enum.uniq() |> Enum.sort()}
      err -> err
    end
  end

  def normalize(_), do: {:error, "permissions must be a list of permission names"}

  @doc "True for a data class (`phi_data`): a restriction on who may see the worktree."
  @spec data_class?(String.t()) :: boolean()
  def data_class?(canonical) do
    match?({:ok, %{kind: k}} when k in @data_classes, parse(canonical))
  end

  @doc "The permission without its optional marker, e.g. `network?:h:443` → `network:h:443`."
  @spec required_form(String.t()) :: String.t()
  def required_form(canonical) do
    case parse(canonical) do
      {:ok, %{canonical: c}} -> String.replace(c, ~r/\A([a-z_]+)\?/, "\\1")
      _ -> canonical
    end
  end

  # ---- grant_by ----------------------------------------------------------------

  @doc """
  Who may grant `canonical` in a workspace with guardrails `block`: `:operator`
  or `:coordinator`. An explicit binding `grant_by` wins; otherwise the §5.1
  default (`prod_ssh` operator, `prod_read` coordinator only when the binding is
  `enforced_read_only`, `secrets:` operator when the binding is tagged `prod`,
  everything else coordinator). A data class has no grant: anyone may add it.
  """
  @spec grant_by(String.t(), map()) :: :operator | :coordinator
  def grant_by(canonical, block) do
    case parse(canonical) do
      {:ok, %{kind: kind} = p} when kind in @data_classes -> default_grant_by(p, nil)
      {:ok, p} -> binding_grant_by(p, binding(block, p))
      _ -> :operator
    end
  end

  defp binding_grant_by(p, binding) do
    case binding && Map.get(binding, "grant_by") do
      "operator" -> :operator
      "coordinator" -> :coordinator
      _ -> default_grant_by(p, binding)
    end
  end

  defp default_grant_by(%{kind: :prod_ssh}, _), do: :operator
  defp default_grant_by(%{kind: :prod_read}, %{"enforced_read_only" => true}), do: :coordinator
  defp default_grant_by(%{kind: :prod_read}, _), do: :operator

  defp default_grant_by(%{kind: :secrets}, %{"tags" => tags}) when is_list(tags),
    do: if("prod" in tags, do: :operator, else: :coordinator)

  defp default_grant_by(_, _), do: :coordinator

  # The binding for a permission: the exact key, then the key without the port
  # (`network:host`), then the bare kind (`network`, `secrets`).
  defp binding(block, %{kind: kind, canonical: canonical}) do
    bindings =
      case block do
        %{"bindings" => %{} = b} -> b
        _ -> %{}
      end

    required = required_form(canonical)

    [required, strip_default_port(required), Atom.to_string(kind)]
    |> Enum.find_value(fn key ->
      case Map.get(bindings, key) do
        %{} = b -> b
        _ -> nil
      end
    end)
  end

  defp strip_default_port(key), do: String.replace(key, ~r/:443\z/, "")

  # ---- authority ---------------------------------------------------------------

  @doc """
  The `permission_events` implied by changing a ticket's permissions from `old`
  to `new` (both canonical lists) as `authority`, or the refusal.
  """
  @spec plan([String.t()], [String.t()], authority(), map()) ::
          {:ok, [planned()]} | {:error, String.t()}
  def plan(old, new, authority, block) do
    removed = old -- new
    added = new -- old

    with :ok <- check_removals(removed, authority),
         :ok <- check_additions(added, authority) do
      {:ok,
       Enum.map(removed, &%{permission: &1, event: :revoked}) ++
         Enum.map(added, &%{permission: &1, event: added_event(&1, authority, block)})}
    end
  end

  defp check_removals([], _), do: :ok

  defp check_removals(removed, :restricted),
    do: {:error, restricted("remove #{Enum.join(removed, ", ")}")}

  defp check_removals(removed, authority) do
    case Enum.filter(removed, &data_class?/1) do
      [] ->
        :ok

      [_ | _] = classes when authority != :operator ->
        {:error,
         "removing #{Enum.join(classes, ", ")} loosens a restriction on who may see the " <>
           "worktree; it is operator-only (a #{authority} token may only add it)"}

      _ ->
        :ok
    end
  end

  defp check_additions([], _), do: :ok

  defp check_additions(added, :restricted),
    do: {:error, restricted("declare #{Enum.join(added, ", ")}")}

  defp check_additions(_added, _authority), do: :ok

  defp restricted(what),
    do:
      "only a coordinator or the operator may #{what}: ticket permissions are never set by a " <>
        "worker or a refine session (a refine session may suggest them)"

  defp added_event(canonical, :coordinator, block) do
    if grant_by(canonical, block) == :operator, do: :requested, else: :declared
  end

  defp added_event(_canonical, _authority, _block), do: :declared

  @doc "`:ok`, or the refusal, for `authority` granting or denying a pending `canonical`."
  @spec authorize_decision(String.t(), authority(), map()) :: :ok | {:error, String.t()}
  def authorize_decision(canonical, authority, block) do
    case {authority, grant_by(canonical, block)} do
      {:operator, _} ->
        :ok

      {:coordinator, :coordinator} ->
        :ok

      {:restricted, _} ->
        {:error, restricted("grant or deny #{canonical}")}

      {_, :operator} ->
        {:error, "#{canonical} is grant_by: operator; only the operator may decide it"}
    end
  end

  # ---- defaults ----------------------------------------------------------------

  @doc """
  The workspace's `guardrails.defaults.permissions` then `repo`'s
  `guardrails.repos.<repo>.defaults.permissions`, canonical, each with the
  `permission_events` source it is recorded under. Unparsable entries are
  dropped (config validation is what refuses them on write).
  """
  @spec defaults(map(), String.t() | nil) :: [{String.t(), :workspace_default | :repo_default}]
  def defaults(block, repo) do
    ws = from_defaults(Map.get(block, "defaults"), :workspace_default)

    repo_entries =
      with repo when is_binary(repo) <- repo,
           %{} = repos <- Map.get(block, "repos"),
           %{} = entry <- Map.get(repos, repo) do
        from_defaults(Map.get(entry, "defaults"), :repo_default)
      else
        _ -> []
      end

    Enum.uniq_by(ws ++ repo_entries, &elem(&1, 0))
  end

  defp from_defaults(%{"permissions" => list}, source) when is_list(list) do
    for raw <- list, {:ok, %{canonical: c}} <- [parse(raw)], do: {c, source}
  end

  defp from_defaults(_, _), do: []
end
