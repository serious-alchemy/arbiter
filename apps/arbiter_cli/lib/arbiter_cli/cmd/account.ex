defmodule ArbiterCli.Cmd.Account do
  @moduledoc """
  `arb account <verb>` — provider accounts (P11, `docs/provider-account-design.md`
  §2.5). An account is the identity a Claude/Codex/Antigravity
  credential, quota snapshot and concurrency ceiling all hang off (§2.4) — it
  survives credential rotation because none of them ever point at the
  credential itself.

      arb account list                              [--provider claude|codex|antigravity]
                                     [--include-merged]
                                     By default merged-away accounts (from a
                                     prior `arb account merge`) are hidden;
                                     pass --include-merged to see them too.
      arb account show   <ref>
                                     <ref> is a uuid, "provider:slug", or a
                                     bare slug (only unambiguous if no other
                                     provider shares it)
      arb account create <provider> <slug> [--label ...] [--plan ...]
                                     [--max-concurrent N]
                                     No credential is required at creation
                                     time (§2.4 — operator-asserted identity).
      arb account set    <ref> [--max-concurrent N|none]
                                     [--threshold-mode flat|paced]
                                     [--weekly-threshold F] [--paced-floor F]
                                     [--weekly-paced-floor F]
                                     `--max-concurrent`: the account
                                     concurrency ceiling (P8, §4.2): at most N
                                     workers may run on this account across
                                     every workspace metered under it. `none`
                                     clears it — the ceiling is opt-in (§4.4)
                                     and an account without one behaves
                                     exactly as it did before P8.
                                     `--threshold-mode` / `--weekly-threshold`
                                     / `--paced-floor` / `--weekly-paced-floor`
                                     (bd-c7ll4t): a partial merge into the
                                     account's `quota_config` — the gate
                                     settings `Arbiter.Quota.Gate` resolves as
                                     `min(account, workspace)`. Only the given
                                     fields change; a sibling key already set
                                     (e.g. `throttle_threshold`) is untouched.
                                     At least one flag is required.
      arb account attach <workspace-id> <provider> <ref> [--share N]
                                     Points a workspace at an account for a
                                     provider — writes/updates the
                                     workspace_provider_accounts row.
                                     `--share N` is this workspace's cap on
                                     its use of the account ceiling (§4.3) —
                                     a **cap, not a reservation**: shares may
                                     sum to more than the ceiling, and that is
                                     the useful configuration.
      arb account rotate <ref> --kind oauth_token|api_key|cli_credentials_file
                                     --env-var VAR (--secret VALUE | --secret-file PATH | -)
                                     [--scopes a,b]
                                     Inserts a new active credential and
                                     retires the previous one of the same
                                     kind. A data operation, not automated
                                     rotation (§11) — the secret is never
                                     printed or logged, by this command or any
                                     other.
      arb account rotate <ref> --kind cli_credentials_path --secret DIR
                                     Points the quota poller at a dedicated
                                     Claude grant by location (bd-b632tz):
                                     DIR is a CLAUDE_CONFIG_DIR logged in with
                                     `CLAUDE_CONFIG_DIR=DIR claude auth login`
                                     (or its .credentials.json). Only the
                                     path is stored; the server re-reads the
                                     token each poll and has the CLI refresh
                                     it. --env-var defaults to
                                     CLAUDE_CONFIG_DIR.
      arb account merge  <from-ref> --into <into-ref>
                                     Re-points usage_events, provider_credentials
                                     and workspace_provider_accounts from
                                     <from-ref> to <into-ref>, collapses the
                                     provider's quota snapshot, and soft-deletes
                                     <from-ref> (merged_into_id set). All-or-
                                     nothing (§2.5) — the operationally
                                     critical command in this design.
      arb account delete <ref>       [--detach] [--hard]
                                     Soft-deletes by default: hidden from
                                     `arb account list` and every account
                                     picker, but the row and its usage_events
                                     attribution are kept (`arb usage --by
                                     account` still resolves it). Every
                                     active credential is retired first,
                                     never printed. Refused, with a reason,
                                     while the account is attached to a
                                     workspace (pass --detach to detach as
                                     part of the delete), is required by a
                                     workspace's implementer/reviewer
                                     settings (not bypassed by --detach), or
                                     is pinned by a running task's provider
                                     routing. `--hard` destroys the row
                                     outright instead — only for an account
                                     with no usage rows and no credentials,
                                     ever.

      arb account login  <ref>       Log the account in through the provider
                                     CLI's own login, run by the server in a
                                     hidden tmux session (login relay). Prints
                                     the sign-in URL (and a device code when
                                     the flow has one); when the CLI waits for
                                     a pasted code it asks for it at a hidden
                                     prompt — never an argument, which `ps`
                                     would show. Exits non-zero on failure,
                                     timeout or cancel.

  All verbs go through the REST API at `/api/accounts`.
  """

  alias ArbiterCli.{Client, Output}
  alias ArbiterCli.Cmd.Account.Login

  @switches [
    provider: :string,
    label: :string,
    plan: :string,
    # :string, not :integer, so `--max-concurrent none` can clear the
    # ceiling — it is nullable and `nil` means "no ceiling" (§4.4).
    max_concurrent: :string,
    threshold_mode: :string,
    weekly_threshold: :string,
    paced_floor: :string,
    weekly_paced_floor: :string,
    share: :integer,
    kind: :string,
    env_var: :string,
    secret: :string,
    secret_file: :string,
    # refused by `login`: a code must never ride in argv
    code: :string,
    scopes: :string,
    into: :string,
    json: :boolean,
    include_merged: :boolean,
    detach: :boolean,
    hard: :boolean
  ]

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      {opts, rest, _invalid} = OptionParser.parse(argv, switches: @switches)
      mode = if opts[:json], do: :json, else: :text

      case rest do
        ["list" | _] ->
          list(opts, mode)

        ["show" | args] ->
          show(args, mode)

        ["create" | args] ->
          create(args, opts, mode)

        ["set" | args] ->
          set(args, opts, mode)

        ["attach" | args] ->
          attach(args, opts, mode)

        ["rotate" | args] ->
          rotate(args, opts, mode)

        ["merge" | args] ->
          merge(args, opts, mode)

        ["delete" | args] ->
          delete(args, opts, mode)

        ["login" | args] ->
          Login.run(args, opts)

        [] ->
          Output.die(
            "account requires a subcommand",
            "verbs: list, show, create, set, attach, rotate, merge, delete, login"
          )

        [unknown | _] ->
          Output.die("unknown account subcommand: #{unknown}")
      end
    end
  end

  # ---- list ----------------------------------------------------------------

  defp list(opts, mode) do
    params =
      []
      |> then(fn p -> if opts[:provider], do: [{:provider, opts[:provider]} | p], else: p end)
      |> then(fn p -> if opts[:include_merged], do: [{:include_merged, "true"} | p], else: p end)

    case Client.get("/api/accounts", params) do
      {:ok, %{"data" => accounts}} -> emit_list(accounts, mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp emit_list(accounts, :json), do: IO.puts(Jason.encode!(%{data: accounts}))
  defp emit_list([], :text), do: IO.puts("(no accounts)")

  defp emit_list(accounts, :text) do
    Enum.each(accounts, fn a ->
      ceiling = if a["max_concurrent"], do: " max_concurrent=#{a["max_concurrent"]}", else: ""
      state = if a["enabled"], do: "", else: "  [disabled]"
      merged = if a["merged_into_id"], do: "  [merged -> #{a["merged_into_id"]}]", else: ""
      IO.puts("#{a["provider"]}:#{a["slug"]}  (#{a["id"]})#{ceiling}#{state}#{merged}")
    end)
  end

  # ---- show ------------------------------------------------------------

  defp show(args, mode) do
    ref = one_ref!(args, "show")

    case Client.get("/api/accounts/" <> URI.encode(ref)) do
      {:ok, account} -> emit_show(account, mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp emit_show(account, :json), do: IO.puts(Jason.encode!(account))

  defp emit_show(account, :text) do
    IO.puts("Provider:    #{account["provider"]}")
    IO.puts("Slug:        #{account["slug"]}")
    IO.puts("ID:          #{account["id"]}")
    IO.puts("Label:       #{account["label"] || "-"}")
    IO.puts("Plan:        #{account["plan"] || "-"}")
    IO.puts("Enabled:     #{account["enabled"]}")
    IO.puts("Max concurrent: #{account["max_concurrent"] || "(none)"}")

    emit_merged_into(account["merged_into_id"])

    IO.puts("")
    IO.puts("Credentials:")
    emit_show_section(account["credentials"], &emit_credential_line/1)

    IO.puts("")
    IO.puts("Workspaces:")
    emit_show_section(account["workspaces"], &emit_link_line/1)
  end

  defp emit_merged_into(nil), do: :ok
  defp emit_merged_into(id), do: IO.puts("Merged into: #{id}")

  defp emit_show_section(nil, _fun), do: IO.puts("  (none)")
  defp emit_show_section([], _fun), do: IO.puts("  (none)")
  defp emit_show_section(items, fun), do: Enum.each(items, fun)

  defp emit_credential_line(c) do
    status = if c["active"], do: "active", else: "retired #{c["retired_at"]}"
    IO.puts("  #{c["kind"]} (#{c["env_var"]}) fingerprint=#{c["fingerprint"]}  #{status}")
  end

  defp emit_link_line(l) do
    share = if l["share"], do: " share=#{l["share"]}", else: ""
    IO.puts("  workspace #{l["workspace_id"]}#{share}")
  end

  # ---- create ------------------------------------------------------------

  defp create(args, opts, mode) do
    {provider, slug} = provider_and_ref!(args, "create")

    payload =
      %{"provider" => provider, "slug" => slug}
      |> maybe_put("label", opts[:label])
      |> maybe_put("plan", opts[:plan])
      |> maybe_put("max_concurrent", max_concurrent!(opts))

    case Client.post("/api/accounts", payload) do
      {:ok, account} -> emit_written(account, "created", mode)
      {:error, err} -> Output.die(err)
    end
  end

  # ---- set ---------------------------------------------------------------

  # P8 (`docs/provider-account-design.md` §4.2): the account concurrency
  # ceiling. A PATCH rather than its own verb endpoint — it edits one column
  # on an existing row.
  defp set(args, opts, mode) do
    ref = one_ref!(args, "set")

    payload =
      %{}
      |> maybe_put_ceiling(opts)
      |> maybe_put_quota_config(opts)

    if payload == %{} do
      Output.die(
        "account set requires at least one of --max-concurrent, --threshold-mode, " <>
          "--weekly-threshold, --paced-floor, --weekly-paced-floor"
      )
    end

    case Client.patch("/api/accounts/" <> URI.encode(ref), payload) do
      {:ok, account} -> emit_set(account, mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp maybe_put_ceiling(payload, opts) do
    case Keyword.fetch(opts, :max_concurrent) do
      {:ok, _} ->
        ceiling =
          case max_concurrent!(opts) do
            :clear -> nil
            value -> value
          end

        Map.put(payload, "max_concurrent", ceiling)

      :error ->
        payload
    end
  end

  defp maybe_put_quota_config(payload, opts) do
    quota_config =
      %{}
      |> maybe_put("threshold_mode", opts[:threshold_mode])
      |> maybe_put(
        "weekly_threshold",
        parse_fraction!(opts[:weekly_threshold], "--weekly-threshold")
      )
      |> maybe_put("paced_floor", parse_fraction!(opts[:paced_floor], "--paced-floor"))
      |> maybe_put(
        "weekly_paced_floor",
        parse_fraction!(opts[:weekly_paced_floor], "--weekly-paced-floor")
      )

    if quota_config == %{}, do: payload, else: Map.put(payload, "quota_config", quota_config)
  end

  defp parse_fraction!(nil, _flag), do: nil

  defp parse_fraction!(value, flag) do
    case Float.parse(value) do
      {f, ""} when f > 0 and f <= 1 ->
        f

      _ ->
        Output.die("#{flag} must be a number in 0..1 (got #{inspect(value)})")
    end
  end

  defp emit_set(account, :json), do: IO.puts(Jason.encode!(account))

  defp emit_set(account, :text) do
    quota_config = account["quota_config"] || %{}

    IO.puts(
      "#{account["provider"]}:#{account["slug"]} max_concurrent=" <>
        "#{account["max_concurrent"] || "(none)"}" <>
        " threshold_mode=#{quota_config["threshold_mode"] || "flat"}"
    )
  end

  # ---- attach ------------------------------------------------------------

  defp attach(args, opts, mode) do
    case args do
      [workspace_id, provider, ref | _] ->
        payload =
          %{"workspace_id" => workspace_id, "provider" => provider}
          |> maybe_put("share", opts[:share])

        case Client.post("/api/accounts/" <> URI.encode(ref) <> "/attach", payload) do
          {:ok, link} -> emit_attach(link, mode)
          {:error, err} -> Output.die(err)
        end

      _ ->
        Output.die("account attach requires <workspace-id> <provider> <ref>")
    end
  end

  defp emit_attach(link, :json), do: IO.puts(Jason.encode!(link))

  defp emit_attach(link, :text) do
    share = if link["share"], do: " share=#{link["share"]}", else: ""

    IO.puts(
      "attached workspace #{link["workspace_id"]} -> account #{link["provider_account_id"]}#{share}"
    )
  end

  # ---- rotate ------------------------------------------------------------

  defp rotate(args, opts, mode) do
    ref = one_ref!(args, "rotate")
    kind = opts[:kind] || Output.die("account rotate requires --kind")
    env_var = opts[:env_var] || default_env_var(kind)
    secret = resolve_secret!(kind, opts, args)

    payload =
      %{"kind" => kind, "env_var" => env_var, "secret" => secret}
      |> maybe_put("scopes", split_scopes(opts[:scopes]))

    case Client.post("/api/accounts/" <> URI.encode(ref) <> "/rotate", payload) do
      {:ok, credential} -> emit_rotated(credential, mode)
      {:error, err} -> Output.die(err)
    end
  end

  # Never prints the secret it just wrote — only shape/metadata a rotation
  # audit trail needs (P11 acceptance: never display or log the value).
  defp emit_rotated(credential, :json) do
    credential
    |> Map.drop(["secret"])
    |> Jason.encode!()
    |> IO.puts()
  end

  defp emit_rotated(credential, :text) do
    IO.puts("rotated #{credential["kind"]} credential (fingerprint=#{credential["fingerprint"]})")
  end

  # A `cli_credentials_path` names a location the server reads, so it gets a
  # default env var and is sent as an absolute path: the server's cwd is not
  # the caller's.
  defp default_env_var("cli_credentials_path"), do: "CLAUDE_CONFIG_DIR"
  defp default_env_var(_kind), do: Output.die("account rotate requires --env-var")

  defp resolve_secret!("cli_credentials_path", opts, _args) do
    case opts[:secret] do
      path when is_binary(path) and path != "" -> Path.expand(path)
      _ -> Output.die("account rotate --kind cli_credentials_path requires --secret DIR")
    end
  end

  defp resolve_secret!(_kind, opts, args), do: resolve_secret!(opts, args)

  defp resolve_secret!(opts, args) do
    cond do
      opts[:secret] && opts[:secret_file] ->
        Output.die("pass only one of --secret / --secret-file")

      is_binary(opts[:secret]) ->
        opts[:secret]

      is_binary(opts[:secret_file]) ->
        case File.read(opts[:secret_file]) do
          {:ok, contents} ->
            String.trim(contents)

          {:error, reason} ->
            Output.die("cannot read --secret-file: #{:file.format_error(reason)}")
        end

      "-" in args ->
        IO.read(:stdio, :eof) |> to_string() |> String.trim()

      true ->
        Output.die(
          "account rotate requires a secret: pass --secret, --secret-file <path>, or - (stdin)"
        )
    end
  end

  defp split_scopes(nil), do: nil
  defp split_scopes(str), do: str |> String.split(",") |> Enum.map(&String.trim/1)

  # ---- merge ------------------------------------------------------------

  defp merge(args, opts, mode) do
    from_ref = one_ref!(args, "merge")
    into_ref = opts[:into] || Output.die("account merge requires --into <ref>")

    case Client.post("/api/accounts/" <> URI.encode(from_ref) <> "/merge", %{"into" => into_ref}) do
      {:ok, account} -> emit_merged(account, mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp emit_merged(account, :json), do: IO.puts(Jason.encode!(account))

  defp emit_merged(account, :text),
    do:
      IO.puts("merged into account #{account["provider"]}:#{account["slug"]} (#{account["id"]})")

  # ---- delete --------------------------------------------------------------

  defp delete(args, opts, mode) do
    ref = one_ref!(args, "delete")

    params =
      []
      |> then(fn p -> if opts[:detach], do: [{:detach, "true"} | p], else: p end)
      |> then(fn p -> if opts[:hard], do: [{:hard, "true"} | p], else: p end)

    case Client.delete("/api/accounts/" <> URI.encode(ref), params) do
      {:ok, account} -> emit_deleted(account, opts[:hard], mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp emit_deleted(account, _hard, :json), do: IO.puts(Jason.encode!(account))

  defp emit_deleted(account, true, :text),
    do: IO.puts("deleted account #{account["provider"]}:#{account["slug"]} (#{account["id"]})")

  defp emit_deleted(account, _hard, :text),
    do:
      IO.puts("soft-deleted account #{account["provider"]}:#{account["slug"]} (#{account["id"]})")

  # ---- output ------------------------------------------------------------

  defp emit_written(account, _verb, :json), do: IO.puts(Jason.encode!(account))

  defp emit_written(account, verb, :text),
    do: IO.puts("#{verb} account #{account["provider"]}:#{account["slug"]} (#{account["id"]})")

  # ---- helpers -----------------------------------------------------------

  defp one_ref!(args, verb) do
    case Enum.reject(args, &(&1 == "-")) do
      [ref | _] -> ref
      [] -> Output.die("account #{verb} requires a ref (uuid, provider:slug, or slug)")
    end
  end

  defp provider_and_ref!(args, verb) do
    case args do
      [provider, slug | _] -> {provider, slug}
      _ -> Output.die("account #{verb} requires <provider> <slug>")
    end
  end

  # `nil` when the flag was not given at all, so `maybe_put/3` drops it;
  # an explicit `none` is the sentinel that clears the ceiling.
  defp max_concurrent!(opts) do
    case opts[:max_concurrent] do
      nil -> nil
      value when value in ~w(none nil null clear unset) -> :clear
      value -> parse_max_concurrent(value)
    end
  end

  defp parse_max_concurrent(value) do
    case Integer.parse(value) do
      {n, ""} when n >= 0 ->
        n

      _ ->
        Output.die(
          "--max-concurrent must be a non-negative integer, or `none` to clear it (got #{inspect(value)})"
        )
    end
  end

  defp maybe_put(map, key, :clear), do: Map.put(map, key, nil)
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
