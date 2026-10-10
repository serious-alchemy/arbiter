defmodule Arbiter.Agents.Codex.Security do
  @moduledoc """
  Translates a provider-agnostic `Arbiter.Agents.SecurityPolicy` into Codex's
  concrete deny mechanism — the Codex analogue of
  `Arbiter.Agents.Claude.Security` and `Arbiter.Agents.Gemini.Security`
  (bd-99emmd, gap G11 of the bd-7tgosa Codex parity analysis).

  ## Mechanism: execpolicy `.rules`

  Codex evaluates every shell command it is about to run against the
  *execpolicy* rule files in `$CODEX_HOME/rules/*.rules`. A
  `prefix_rule(pattern=[...], decision="forbidden")` rejects any command whose
  leading tokens match. `Arbiter.Agents.Codex.ConfigDir` writes the text this
  module generates to `$CODEX_HOME/rules/arbiter.rules` in the spawn's own home.

  Probed against codex-cli 0.153.4 with a mock Responses backend (no quota):

    * the rules are enforced under `--dangerously-bypass-approvals-and-sandbox`
      (the default `:bypass` mode) as well as under `sandbox_mode`
      `workspace-write`: a `git push --force origin main` came back
      ``rejected: Arbiter deny: no_force_push`` and the push never happened;
    * a compound script (`cd /tmp && git push --force …`, `a; git push -f …`)
      is split into its simple commands and each is matched;
    * the match is on literal leading tokens, so a command wrapped in
      `bash -c '…'` (an opaque string) or carrying a global option before the
      subcommand (`git -C . push --force`) is **not** matched.

  ## Honesty about enforcement level

  Like Claude's deny list these are *permission-layer* guards: they stop the
  agent running a denied command in the common shapes, not a determined
  escape. The filesystem categories (`:no_outside_writes`) have no shell-prefix
  analogue; under `:auto` they are enforced by Codex's own kernel sandbox
  (`sandbox_mode = "workspace-write"`), under `:bypass` they are not. Reads are
  not confined by either (`:no_secret_reads` is the same literal-prefix
  approximation Claude's `Bash(cat .env:*)` is). `:no_async_wait` has no Codex
  analogue (no `Monitor` / `ScheduleWakeup` tools exist).

  Backend-neutral: nothing here knows which model backend the spawn talks to.
  """

  alias Arbiter.Agents.SecurityPolicy

  @type pattern :: [String.t() | [String.t()]]

  # Network tools denied when `sandbox.network` is false (Claude's list).
  @network_tools ~w(curl wget nc ncat telnet)

  # Readers that would print a secret file, and the files themselves. Token
  # exact, so only the whole-path spellings are caught.
  @readers ~w(cat less more head tail bat)
  @secret_files [
    ".env",
    ".env.local",
    ".env.production",
    ".netrc",
    "~/.netrc",
    "~/.aws/credentials",
    "~/.ssh/id_rsa",
    "~/.ssh/id_ed25519"
  ]

  @doc """
  The execpolicy rule file text for `policy`, or `""` when nothing is denied.
  """
  @spec rules(SecurityPolicy.t()) :: String.t()
  def rules(%SecurityPolicy{} = policy) do
    policy
    |> labelled()
    |> Enum.flat_map(fn {label, pattern} ->
      case render_pattern(pattern) do
        nil ->
          []

        rendered ->
          [
            "prefix_rule(pattern=#{rendered}, decision=\"forbidden\", " <>
              "justification=#{quote_token!("Arbiter deny: #{label}")})\n"
          ]
      end
    end)
    |> Enum.uniq()
    |> Enum.join()
  end

  @doc """
  The forbidden command prefixes for `policy`. Each pattern element is a
  literal token or a list of alternatives, execpolicy's own pattern shape.
  """
  @spec prefixes(SecurityPolicy.t()) :: [pattern()]
  def prefixes(%SecurityPolicy{} = policy), do: policy |> labelled() |> Enum.map(&elem(&1, 1))

  # ---- internals ---------------------------------------------------------

  defp labelled(%SecurityPolicy{permissions: perms, sandbox: sandbox}) do
    (Enum.flat_map(perms.safe_defaults, fn category ->
       for pattern <- expand_category(category), do: {Atom.to_string(category), pattern}
     end) ++
       for(pattern <- network_deny(sandbox), do: {"network_off", pattern}) ++
       for(
         pattern <- Enum.flat_map(perms.deny, &bash_rule/1),
         do: {"operator_deny", pattern}
       ))
    |> Enum.uniq()
  end

  defp expand_category(:no_destructive_fs) do
    [
      ["rm", ["-rf", "-fr", "-Rf", "-fR", "-rF", "-Fr"]],
      ["rm", "-r", "-f"],
      ["rm", "-f", "-r"],
      ["rm", "--recursive", "--force"],
      ["rm", "--force", "--recursive"],
      ["sudo", "rm"],
      ["mkfs"],
      ["dd"]
    ]
  end

  # `--force-with-lease` is intentionally not denied (same as Claude's list).
  defp expand_category(:no_force_push) do
    [
      ["git", "push", ["--force", "-f"]],
      ["git", "push", "origin", ["--force", "-f"]]
    ]
  end

  defp expand_category(:no_secret_reads) do
    for reader <- @readers, do: [reader, @secret_files]
  end

  defp expand_category(:no_pr_create), do: [["gh", "pr", "create"], ["glab", "mr", "create"]]

  # A host in the middle of a command line can't be matched by a prefix, so
  # the upload-shaped `curl` flags are denied instead (agy's approach).
  defp expand_category(:no_public_upload) do
    [["curl", ["-F", "--form", "-T", "--upload-file"]]]
  end

  defp expand_category(:no_gh_publish) do
    [["gh", "gist", ["create", "edit"]], ["gh", "issue", "comment"]]
  end

  defp expand_category(:no_ci_watch) do
    [["gh", "run", ["watch", "view"]], ["gh", "pr", "checks", "--watch"]]
  end

  # :no_outside_writes (kernel sandbox only), :no_async_wait (no such tools).
  defp expand_category(_other), do: []

  defp network_deny(%{network: false}), do: for(tool <- @network_tools, do: [tool])
  defp network_deny(_sandbox), do: []

  # An operator `deny` entry in Claude's grammar. Only `Bash(<prefix>)` /
  # `Bash(<prefix>:*)` / `Bash(<prefix> *)` is a command prefix; a glob in the
  # middle of the command can't be expressed and every other tool kind has no
  # Codex analogue.
  defp bash_rule("Bash(" <> rest) do
    case String.split_at(rest, -1) do
      {inner, ")"} ->
        inner
        |> String.replace(~r/(:\*|\s\*)\z/, "")
        |> String.split()
        |> case do
          [] -> []
          tokens -> if Enum.any?(tokens, &String.contains?(&1, "*")), do: [], else: [tokens]
        end

      _ ->
        []
    end
  end

  defp bash_rule(_other), do: []

  defp render_pattern(pattern) do
    parts =
      Enum.map(pattern, fn
        alts when is_list(alts) -> render_alternatives(alts)
        token -> quote_token(token)
      end)

    if Enum.any?(parts, &is_nil/1), do: nil, else: "[" <> Enum.join(parts, ", ") <> "]"
  end

  defp render_alternatives(alts) do
    quoted = Enum.map(alts, &quote_token/1)
    if Enum.any?(quoted, &is_nil/1), do: nil, else: "[" <> Enum.join(quoted, ", ") <> "]"
  end

  # A Starlark string literal, or `nil` for a token that would need escaping
  # (quote, backslash, control character). The pattern is dropped rather than
  # emitted malformed: a bad rule file would make Codex refuse to start.
  defp quote_token(token) when is_binary(token) do
    if token != "" and String.printable?(token) and not String.match?(token, ~r/["\\\x00-\x1f]/),
      do: ~s("#{token}")
  end

  defp quote_token!(token), do: quote_token(token) || ~s("Arbiter deny")
end
