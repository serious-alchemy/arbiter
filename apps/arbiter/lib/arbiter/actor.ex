defmodule Arbiter.Actor do
  @moduledoc """
  Who performed a write — **attribution only**.

  An `%Arbiter.Actor{}` names the party behind a mutation so the audit trail
  (PaperTrail version rows, the durable `events` log, the dashboard `/audit`
  page, `arb show`) can tell an operator's dashboard click from a coordinator
  MCP call, a worker updating its own ticket, an autopilot promotion or a
  system reconciler. It is **not** authorization: nothing reads an actor to
  allow or refuse an action, and there is no users table behind it.

  ## Shape

  `kind` is one of `:operator | :coordinator | :worker | :autopilot | :system`
  (plus `:refine`, the browser-hosted refinement session, which keeps the
  `refine:<issue>` label it already had, and `:node`, an enrolled remote node
  acting with its own `arbn_` credential — `node:<name>`); `id` narrows it (the worker's ticket,
  the operator's dashboard identity, the name of the reconciler). The stable
  string form is `label/1`: `"coordinator"`, `"worker:bd-xxxx"`,
  `"operator:ryan"`, `"operator (unauthenticated)"`, `"autopilot"`,
  `"system:merge_queue"`. That label is what gets persisted; `parse/1` reads it
  back (and classifies the free-form labels older writers stored: `"dashboard"`,
  `"cli"`, `"loop:proposal:<id>"`).

  ## Edge derivation

    * MCP / REST / CLI — `from_scope/1` on the bearer token's `Arbiter.MCP.Scope`
      (the tier plus its claims). `Arbiter.MCP.Catalog.call/3` and
      `ArbiterWeb.Plugs.ApiAuth` install it for the request.
    * Dashboard — `operator/1` with the `ArbiterWeb.DashboardAuth` identity
      (`operator(nil)` is the unauthenticated operator).
    * Scheduler / reconcilers — `autopilot/0` / `system/1`, installed once by the
      long-lived process with `put/1`.

  ## Ambient actor

  Write paths are many and deep, so the actor is also carried **per process**
  (`put/1`, `with_actor/2`, `current/0`) and picked up where a version or event
  row is written, via `resolve/1`: an explicit `actor:` always wins, the ambient
  one is the fallback, and neither means an unattributed write (`nil`). The
  ambient value is deliberately not inherited by spawned tasks.
  """

  # `node/0,1` below is the actor constructor, not the Erlang node name.
  import Kernel, except: [node: 0, node: 1]

  alias Arbiter.MCP.Scope

  @kinds [:operator, :coordinator, :worker, :autopilot, :system, :refine, :node]
  @pdict_key :arbiter_actor
  @unauthenticated "operator (unauthenticated)"
  @cli_id "cli"

  @enforce_keys [:kind]
  defstruct [:kind, :id]

  @type kind :: :operator | :coordinator | :worker | :autopilot | :system | :refine | :node
  @type t :: %__MODULE__{kind: kind(), id: String.t() | nil}

  @doc "The valid kinds."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  # ---- constructors -----------------------------------------------------------

  @doc "A human at the dashboard or CLI. `nil` is the unauthenticated operator."
  @spec operator(String.t() | nil) :: t()
  def operator(id \\ nil), do: %__MODULE__{kind: :operator, id: id}

  @spec coordinator() :: t()
  def coordinator, do: %__MODULE__{kind: :coordinator}

  @doc "A worker bound to one ticket."
  @spec worker(String.t()) :: t()
  def worker(task_id) when is_binary(task_id), do: %__MODULE__{kind: :worker, id: task_id}

  @doc "A browser-hosted refinement session bound to one issue."
  @spec refine(String.t()) :: t()
  def refine(issue_id) when is_binary(issue_id), do: %__MODULE__{kind: :refine, id: issue_id}

  @doc """
  An enrolled remote node (`Arbiter.Nodes`), named by its operator-visible name
  (or `nil` before it has one). It is not a `Scope` tier: a node credential
  never decodes to a scope, so this is only ever built by the node edge.
  """
  @spec node(String.t() | nil) :: t()
  def node(name \\ nil), do: %__MODULE__{kind: :node, id: name}

  @spec autopilot() :: t()
  def autopilot, do: %__MODULE__{kind: :autopilot}

  @doc "A reconciler or other server-internal actor, optionally named."
  @spec system(String.t() | nil) :: t()
  def system(name \\ nil), do: %__MODULE__{kind: :system, id: name}

  # ---- label ------------------------------------------------------------------

  @doc "The stable string form that is persisted on version and event rows."
  @spec label(t()) :: String.t()
  def label(%__MODULE__{kind: :operator, id: nil}), do: @unauthenticated
  def label(%__MODULE__{kind: kind, id: nil}), do: Atom.to_string(kind)
  def label(%__MODULE__{kind: kind, id: id}), do: "#{kind}:#{id}"

  @doc """
  Read a stored label back into an actor. Total: a label no rule recognises is
  an operator (a human typed it), matching how the audit page has always
  classified unknown actors.
  """
  @spec parse(String.t()) :: t()
  def parse(@unauthenticated), do: operator(nil)
  def parse("coordinator"), do: coordinator()
  def parse("autopilot"), do: autopilot()
  def parse("system"), do: system()
  def parse("worker:" <> id) when id != "", do: worker(id)
  def parse("refine:" <> id) when id != "", do: refine(id)
  def parse("node"), do: node()
  def parse("node:" <> name) when name != "", do: node(name)
  def parse("system:" <> name) when name != "", do: system(name)
  def parse("operator:" <> id) when id != "", do: operator(id)
  # The loop's apply path (`"loop:proposal:<id>"`, `"loop"`) is server-internal.
  def parse("loop" <> _ = label), do: system(label)
  def parse(label) when is_binary(label), do: operator(label)

  @doc "True for every kind except `:operator` — the audit page's Human/Machine split."
  @spec machine?(t()) :: boolean()
  def machine?(%__MODULE__{kind: :operator}), do: false
  def machine?(%__MODULE__{}), do: true

  # ---- derivation -------------------------------------------------------------

  @doc """
  The actor behind an MCP scope. An operator-proof coordinator token (minted
  over the operator socket — the human's own `arb`) is the operator at the CLI;
  `nil` (no token) is unattributed.
  """
  @spec from_scope(Scope.t() | nil) :: t() | nil
  def from_scope(%Scope{tier: :coordinator, operator: true}), do: operator(@cli_id)
  def from_scope(%Scope{tier: :coordinator}), do: coordinator()

  def from_scope(%Scope{tier: :worker, task_id: task_id}) when is_binary(task_id),
    do: worker(task_id)

  def from_scope(%Scope{tier: :refine, issue_id: issue_id}) when is_binary(issue_id),
    do: refine(issue_id)

  def from_scope(%Scope{tier: tier}) when tier in [:worker, :refine],
    do: %__MODULE__{kind: tier}

  def from_scope(_), do: nil

  @doc "Normalise an actor, a scope, a label string or `nil` into an actor (or `nil`)."
  @spec from(term()) :: t() | nil
  def from(%__MODULE__{} = actor), do: actor
  def from(%Scope{} = scope), do: from_scope(scope)
  def from(label) when is_binary(label) and label != "", do: parse(label)
  def from(_), do: nil

  @doc """
  The label of whoever wrote a paper-trail version row, or `nil` when unknown.

  `change_origin` (`"loop:proposal:<id>"`, recorded in the action inputs) names
  the queued proposal behind a loop write and is more specific than the actor
  column, so it wins; a version with neither predates the column or was written
  with no actor in scope.
  """
  @spec of_version(map()) :: String.t() | nil
  def of_version(%{version_action_inputs: %{"change_origin" => origin}})
      when is_binary(origin) and origin != "",
      do: origin

  def of_version(%{actor: actor}) when is_binary(actor) and actor != "", do: actor
  def of_version(_version), do: nil

  # ---- ambient actor ----------------------------------------------------------

  @doc "The calling process's ambient actor, or `nil`."
  @spec current() :: t() | nil
  def current, do: Process.get(@pdict_key)

  @doc "Set (or, with `nil`, clear) the calling process's ambient actor."
  @spec put(t() | nil) :: :ok
  def put(nil) do
    Process.delete(@pdict_key)
    :ok
  end

  def put(%__MODULE__{} = actor) do
    Process.put(@pdict_key, actor)
    :ok
  end

  @doc "Run `fun` with `actor` as the ambient actor, restoring the previous one after."
  @spec with_actor(t() | nil, (-> result)) :: result when result: var
  def with_actor(actor, fun) when is_function(fun, 0) do
    previous = current()
    put(actor)

    try do
      fun.()
    after
      put(previous)
    end
  end

  @doc "The actor for a write: an explicit one wins, else the ambient one, else `nil`."
  @spec resolve(term()) :: t() | nil
  def resolve(explicit), do: from(explicit) || current()

  @doc """
  `resolve/1` rendered as a label. A label string an older writer chose
  (`"loop:proposal:<id>"`, `"cli"`) is returned verbatim, not re-classified.
  """
  @spec resolve_label(term()) :: String.t() | nil
  def resolve_label(explicit) when is_binary(explicit) and explicit != "", do: explicit

  def resolve_label(explicit) do
    case resolve(explicit) do
      nil -> nil
      actor -> label(actor)
    end
  end
end
