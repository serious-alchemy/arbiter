defmodule Arbiter.Sessions.Memory.Staleness do
  @moduledoc """
  Verifies what a memory points at against the code and the ledger, and
  returns a **verdict** (bd-19qve3, RFC §9.4 phase 13). Pure judgement: it
  never moves, rewrites or serves anything. `Arbiter.Sessions.Memory.Checker`
  persists verdicts and quarantines stale memories, and
  `Arbiter.Sessions.Memory.Promotion` refuses stale candidates. The rules are
  written up in `docs/design/memory-promotion-queue.md`.

  ## What is checked, per memory type

  | Type | file:line | modules | ticket ids | URLs |
  |---|---|---|---|---|
  | `project`, `reference` (and untyped) | checked | checked | checked | `unchecked` |
  | `user`, `feedback` | checked | checked | ignored | ignored |

  `user` and `feedback` are behavioural, so they are exempt from the rules that
  exist because code rots; a `file:line` or module citation inside one is still
  a claim about code and is checked the same way. External URLs are never
  fetched: they are listed as `unchecked` and cannot change a verdict.

  ## file:line — content anchors, not line bounds

  "Line N exists" keeps passing after the code has moved. Each citation is
  matched by an **anchor**: the first 16 hex chars of the SHA-256 of the cited
  line, trimmed. Promotion records the anchors in the memory's frontmatter
  (`anchors:`). A memory nobody promoted is anchored on its first successful
  check and the anchor is kept in its verdict (trust on first use). The check
  passes when a line with the anchor's text appears **anywhere** in the file,
  so code that moved within the file still supports the claim and the verdict
  says where it is now (`found_at`). It fails only when the file is gone, or
  the anchor text is gone. Files are read from the committed tree at the
  checkout's `HEAD` (`git cat-file`), never the working tree, so the verdict
  holds for exactly the SHA it records.

  ## Modules

  A dotted name is a citation only when the workspace owns its namespace: the
  root module itself is defined there (`defmodule Arbiter`), or the cited
  name's parent is. Everything else, such as `Ecto.Changeset` or `Mix.Project`,
  is a mention of a dependency. A repo that defines `Mix.Tasks.*` does not
  thereby own `Mix`. An owned name must be defined by `defmodule` or
  `defprotocol` at `HEAD`. A nested definition (`defmodule Inner` inside
  `defmodule Short`) resolves by its full name.

  ## Statuses

    * `:stale` — a pointer definitively no longer resolves: `:file_missing`,
      `:anchor_missing`, `:line_out_of_range`, `:undefined` (module) or
      `:missing` (ticket).
    * `:unverified` — nothing resolved stale, but some citation could not be
      checked: no checkout could be resolved, or a ledger lookup failed. That
      is not evidence of rot, so it is never quarantined.
    * `:ok` — everything checked resolved.

  A failed lookup or a missing checkout can make a verdict `:unverified`, but
  never `:stale`.
  """

  require Ash.Query
  require Logger

  alias Arbiter.Sessions.Memory.Citations
  alias Arbiter.Sessions.Memory.Frontmatter
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.RepoConfig
  alias Arbiter.Tasks.Workspace

  @behavioural ~w(user feedback)
  @stale_statuses [:file_missing, :anchor_missing, :line_out_of_range, :undefined, :missing]
  @anchor_hash ~r/\A[0-9a-f]{16}\z/
  @definition ~S"^\s*(defmodule|defprotocol)\s+[A-Z][A-Za-z0-9_.]*"

  @type status :: :ok | :stale | :unverified

  @type citation :: %{
          required(:kind) => :file | :module | :ticket | :url,
          required(:ref) => String.t(),
          required(:status) => atom(),
          optional(:found_at) => pos_integer()
        }

  @type verdict :: %{
          status: status(),
          type: String.t() | nil,
          content_sha256: String.t(),
          checked_at: DateTime.t(),
          checked_against: %{optional(String.t()) => String.t()},
          citations: [citation()],
          anchors: %{optional(String.t()) => String.t()},
          reasons: [String.t()]
        }

  @doc """
  Verify the memory file at `path`. See `verify_contents/2` for the options.
  """
  @spec verify(Path.t(), keyword()) :: {:ok, verdict()} | {:error, File.posix()}
  def verify(path, opts \\ []) do
    with {:ok, contents} <- File.read(path), do: {:ok, verify_contents(contents, opts)}
  end

  @doc """
  Verify memory text and return its verdict.

  ## Options

    * `:checkouts` — checkout paths to verify against, instead of the memory's
      workspace `repo_paths` (or every workspace's, for a memory with no
      `workspace_id`).
    * `:ticket_prefixes` — the ticket-id prefixes to recognise, instead of every
      workspace's `prefix`.
    * `:anchors` — first-use anchors recorded by an earlier check. Anchors in
      the memory's own frontmatter take precedence.
    * `:establish_anchors` — ignore every recorded anchor and anchor each
      citation on the line it names now. Promotion uses this, and so does an
      explicit re-anchoring restore.
    * `:now` — the `checked_at` timestamp.
  """
  @spec verify_contents(String.t(), keyword()) :: verdict()
  def verify_contents(contents, opts \\ []) when is_binary(contents) do
    fields = Frontmatter.fields(contents)
    text = Frontmatter.body(contents) <> "\n" <> Map.get(fields, "description", "")
    files = Citations.files(text)
    modules = Citations.modules(text)
    checkouts = if files == [] and modules == [], do: [], else: resolve_checkouts(fields, opts)

    {file_results, anchors} = check_files(files, checkouts, recorded_anchors(fields, opts))

    citations =
      file_results ++
        check_modules(modules, checkouts) ++ check_pointers(fields["type"], text, opts)

    %{
      status: status(citations),
      type: fields["type"],
      content_sha256: content_hash(contents),
      checked_at: Keyword.get(opts, :now, DateTime.utc_now()),
      checked_against: Map.new(checkouts, &{&1.path, &1.sha}),
      citations: citations,
      anchors: Map.take(anchors, Enum.map(files, & &1.ref)),
      reasons: reasons(citations)
    }
  end

  @doc """
  The SHA(s) a verdict was checked against, for a frontmatter field: the bare
  SHA for one checkout, `repo@sha` pairs for several, `nil` for none.
  """
  @spec sha_label(%{optional(String.t()) => String.t()}) :: String.t() | nil
  def sha_label(checked_against) do
    case Enum.sort(checked_against) do
      [] -> nil
      [{_path, sha}] -> sha
      pairs -> Enum.map_join(pairs, " ", fn {path, sha} -> "#{Path.basename(path)}@#{sha}" end)
    end
  end

  @doc "The commit `HEAD` names in the checkout at `path`, or `nil`."
  @spec head_sha(Path.t()) :: String.t() | nil
  def head_sha(path) do
    case head(path) do
      [%{sha: sha}] -> sha
      [] -> nil
    end
  end

  @doc "Lowercase hex SHA-256 of a memory's exact bytes — what a verdict is bound to."
  @spec content_hash(binary()) :: String.t()
  def content_hash(contents), do: :sha256 |> :crypto.hash(contents) |> Base.encode16(case: :lower)

  @doc "The `anchors:` frontmatter value for an anchor map: `ref=hash` pairs."
  @spec encode_anchors(%{optional(String.t()) => String.t()}) :: String.t()
  def encode_anchors(anchors) do
    anchors |> Enum.sort() |> Enum.map_join(" ", fn {ref, hash} -> "#{ref}=#{hash}" end)
  end

  @doc "The anchor map an `anchors:` frontmatter value encodes; malformed pairs are dropped."
  @spec decode_anchors(String.t() | nil) :: %{optional(String.t()) => String.t()}
  def decode_anchors(nil), do: %{}

  def decode_anchors(value) when is_binary(value) do
    value
    |> String.split()
    |> Enum.flat_map(&decode_anchor/1)
    |> Map.new()
  end

  defp decode_anchor(pair) do
    case String.split(pair, "=") do
      [_ | [_ | _]] = parts ->
        {ref_parts, [hash]} = Enum.split(parts, -1)
        if hash =~ @anchor_hash, do: [{Enum.join(ref_parts, "="), hash}], else: []

      _ ->
        []
    end
  end

  # ---- checkouts ------------------------------------------------------------

  defp resolve_checkouts(fields, opts) do
    opts
    |> Keyword.get_lazy(:checkouts, fn -> repo_paths(fields["workspace_id"]) end)
    |> Enum.uniq()
    |> Enum.flat_map(&head/1)
  end

  defp head(path) do
    case git(path, ["rev-parse", "--verify", "HEAD^{commit}"]) do
      {:ok, sha} -> [%{path: path, sha: String.trim(sha)}]
      :error -> []
    end
  end

  defp repo_paths(nil) do
    Workspace |> Ash.read!() |> Enum.flat_map(&workspace_paths/1) |> Enum.uniq()
  rescue
    e -> lookup_failed("workspace repo paths", e, [])
  end

  defp repo_paths(workspace_id) do
    case Ash.get(Workspace, workspace_id) do
      {:ok, workspace} -> workspace_paths(workspace)
      {:error, _} -> []
    end
  rescue
    e -> lookup_failed("workspace #{workspace_id}", e, [])
  end

  defp workspace_paths(%Workspace{config: %{"repo_paths" => paths}}) when is_map(paths) do
    paths
    |> Map.values()
    |> Enum.map(&RepoConfig.repo_path_from_config/1)
    |> Enum.reject(&is_nil/1)
  end

  defp workspace_paths(_workspace), do: []

  # ---- file:line ------------------------------------------------------------

  defp recorded_anchors(fields, opts) do
    if Keyword.get(opts, :establish_anchors, false) do
      %{}
    else
      opts |> Keyword.get(:anchors, %{}) |> Map.merge(decode_anchors(fields["anchors"]))
    end
  end

  defp check_files(files, checkouts, anchors) do
    Enum.map_reduce(files, anchors, &check_file(&1, checkouts, &2))
  end

  defp check_file(%{ref: ref}, [], anchors), do: {result(ref, :file, :unverifiable), anchors}

  defp check_file(%{ref: ref} = citation, checkouts, anchors) do
    case Enum.flat_map(checkouts, &read_blob(&1, citation.path)) do
      [] -> {result(ref, :file, :file_missing), anchors}
      contents -> match_anchor(citation, contents, anchors)
    end
  end

  defp read_blob(%{path: path, sha: sha}, file) do
    case git(path, ["cat-file", "blob", "#{sha}:#{file}"]) do
      {:ok, content} -> [lines(content)]
      :error -> []
    end
  end

  defp lines(content) do
    case String.split(content, "\n") do
      [] -> []
      parts -> if List.last(parts) == "", do: Enum.drop(parts, -1), else: parts
    end
  end

  defp match_anchor(%{ref: ref} = citation, contents, anchors) do
    case Map.fetch(anchors, ref) do
      {:ok, hash} -> {find_anchor(ref, hash, contents), anchors}
      :error -> anchor_on_first_use(citation, contents, anchors)
    end
  end

  defp find_anchor(ref, hash, contents) do
    Enum.find_value(contents, result(ref, :file, :anchor_missing), fn lines ->
      case Enum.find_index(lines, &(anchor_hash(&1) == hash)) do
        nil -> nil
        index -> Map.put(result(ref, :file, :ok), :found_at, index + 1)
      end
    end)
  end

  defp anchor_on_first_use(%{ref: ref, line: n}, contents, anchors) do
    case Enum.find_value(contents, &Enum.at(&1, n - 1)) do
      nil ->
        {result(ref, :file, :line_out_of_range), anchors}

      text ->
        {Map.put(result(ref, :file, :ok), :found_at, n), Map.put(anchors, ref, anchor_hash(text))}
    end
  end

  defp anchor_hash(line) do
    :sha256
    |> :crypto.hash(String.trim(line))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  # ---- modules --------------------------------------------------------------

  defp check_modules([], _checkouts), do: []
  defp check_modules(_modules, []), do: []

  defp check_modules(modules, checkouts) do
    defined = Enum.reduce(checkouts, %{top: %{}, all: %{}}, &definitions/2)

    modules
    |> Enum.filter(&owned?(&1, defined.top))
    |> Enum.map(&result(&1, :module, if(defined?(&1, defined.all), do: :ok, else: :undefined)))
  end

  # The module names `defmodule`/`defprotocol` introduce at HEAD, as two sets:
  # `top` holds the column-0 definitions (whose namespaces the workspace owns),
  # `all` adds the indented ones. An indented, nested definition contributes its
  # relative name, which `defined?/2` resolves through its parent; it never
  # makes its own name a root the workspace owns.
  defp definitions(%{path: path, sha: sha}, acc) do
    case git_grep(path, ["-h", "-o", "-E", @definition, sha, "--", "*.ex", "*.exs"]) do
      {:ok, out} -> out |> String.split("\n", trim: true) |> Enum.reduce(acc, &add_definition/2)
      :error -> acc
    end
  end

  defp add_definition(line, %{top: top, all: all}) do
    name = line |> String.split() |> List.last()
    top = if String.starts_with?(line, "def"), do: Map.put(top, name, true), else: top
    %{top: top, all: Map.put(all, name, true)}
  end

  defp owned?(name, top) do
    [root | _] = String.split(name, ".")
    Map.has_key?(top, root) or Map.has_key?(top, parent(name))
  end

  defp defined?(name, all) do
    Map.has_key?(all, name) or nested_defined?(name, all)
  end

  defp nested_defined?(name, all) do
    case parent(name) do
      nil -> false
      parent -> Map.has_key?(all, last_segment(name)) and defined?(parent, all)
    end
  end

  defp parent(name) do
    case name |> String.split(".") |> Enum.split(-1) do
      {[], _} -> nil
      {segments, _} -> Enum.join(segments, ".")
    end
  end

  defp last_segment(name), do: name |> String.split(".") |> List.last()

  # ---- ticket ids and URLs (project / reference only) ------------------------

  defp check_pointers(type, _text, _opts) when type in @behavioural, do: []

  defp check_pointers(_type, text, opts) do
    tickets =
      case Keyword.get_lazy(opts, :ticket_prefixes, &workspace_prefixes/0) do
        [] -> []
        prefixes -> text |> Citations.tickets(prefixes) |> lookup_tickets()
      end

    tickets ++ Enum.map(Citations.urls(text), &result(&1, :url, :unchecked))
  end

  defp workspace_prefixes do
    Workspace |> Ash.read!() |> Enum.map(& &1.prefix) |> Enum.uniq()
  rescue
    e -> lookup_failed("workspace prefixes", e, [])
  end

  defp lookup_tickets([]), do: []

  defp lookup_tickets(ids) do
    found =
      Issue
      |> Ash.Query.filter(id in ^ids)
      |> Ash.Query.select([:id])
      |> Ash.read!()
      |> Map.new(&{&1.id, true})

    Enum.map(ids, &result(&1, :ticket, if(Map.has_key?(found, &1), do: :ok, else: :missing)))
  rescue
    e -> lookup_failed("ticket ids", e, Enum.map(ids, &result(&1, :ticket, :unverifiable)))
  end

  # ---- verdict ---------------------------------------------------------------

  defp result(ref, kind, status), do: %{kind: kind, ref: ref, status: status}

  defp status(citations) do
    cond do
      Enum.any?(citations, &(&1.status in @stale_statuses)) -> :stale
      Enum.any?(citations, &(&1.status == :unverifiable)) -> :unverified
      true -> :ok
    end
  end

  defp reasons(citations) do
    for %{status: status, ref: ref} <- citations, status not in [:ok, :unchecked] do
      "#{ref}: #{describe(status)}"
    end
  end

  defp describe(:file_missing), do: "the file no longer exists at HEAD"
  defp describe(:anchor_missing), do: "the cited line's text no longer appears in the file"
  defp describe(:line_out_of_range), do: "the file has no such line"
  defp describe(:undefined), do: "the module is no longer defined"
  defp describe(:missing), do: "no such ticket"
  defp describe(:unverifiable), do: "could not be checked (no checkout, or the lookup failed)"

  defp lookup_failed(what, exception, fallback) do
    Logger.warning(
      "Arbiter.Sessions.Memory.Staleness: #{what} lookup failed: #{Exception.message(exception)}"
    )

    fallback
  end

  # ---- git -------------------------------------------------------------------

  defp git(path, args) do
    case System.cmd("git", ["-C", path | args], stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      {_out, _code} -> :error
    end
  rescue
    _ in ErlangError -> :error
  end

  # `git grep` exits 1 for "no match", which is an answer, not a failure.
  defp git_grep(path, args) do
    case System.cmd("git", ["-C", path, "grep" | args], stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      {_out, 1} -> {:ok, ""}
      {_out, _code} -> :error
    end
  rescue
    _ in ErlangError -> :error
  end
end
