defmodule ArbiterCli.Cmd.Doctor.SecretsAtRest do
  @moduledoc """
  `arb doctor`'s "secrets at rest" check: which of arbiter's secrets sit inline in
  the service's `EnvironmentFile` (`<data-home>/arbiter.env`) and which are
  references to an external secret manager (`NAME_REF=aws-sm:…`).

  An inline `ARBITER_CLOAK_KEY` or `SECRET_KEY_BASE` is the finding a host
  secret scanner raises (the cloak key then sits in plaintext beside the
  database it protects), so those — and an inline value a `*_REF` pointer
  already shadows, and a pointer with an unrecognised scheme — are a `warn`.
  Other inline provider tokens are listed but do not warn. Values are never
  read into the report; see `ArbiterCli.Cmd.SecretInventory`.

  Tests (and `CliCase`, through `Process.get(:bd2_secrets_probe)`) override the
  host's env file with an env map, or `:absent`.
  """

  alias ArbiterCli.Cmd.Doctor.Checks.Result
  alias ArbiterCli.Cmd.ReleaseDeploy.ReleaseFiles
  alias ArbiterCli.Cmd.SecretInventory

  @name "secrets at rest"

  @spec check() :: Result.t()
  def check, do: check(Process.get(:bd2_secrets_probe, :live))

  @spec check(:live | :absent | %{optional(String.t()) => String.t()}) :: Result.t()
  def check(:absent), do: na()

  def check(:live) do
    path = Path.join(ReleaseFiles.data_home(), "arbiter.env")
    if File.regular?(path), do: check(SecretInventory.env_from_file(path)), else: na()
  end

  def check(env) when is_map(env) do
    entries = SecretInventory.classify(env)
    summary = SecretInventory.summary(entries)

    inline_boot = SecretInventory.inline_boot_secrets(entries)
    shadowed = for %{name: n, state: :shadowed} <- entries, do: n
    invalid = for %{name: n, scheme: "invalid"} <- entries, do: n

    problems =
      Enum.map(inline_boot, &"#{&1} is an inline value") ++
        Enum.map(shadowed -- inline_boot, &"#{&1} has an inline value its _REF pointer overrides") ++
        Enum.map(invalid, &"#{&1}_REF is not an aws-sm:/aws-ssm:/file: reference")

    case problems do
      [] ->
        %Result{name: @name, status: :ok, detail: summary, meta: %{secrets: report(entries)}}

      _ ->
        %Result{
          name: @name,
          status: :warn,
          detail: Enum.join(problems, "; ") <> " (" <> summary <> ")",
          hint:
            "Keep secret values out of arbiter.env: set e.g. ARBITER_CLOAK_KEY_REF=aws-sm:<id>#<key> " <>
              "(also SECRET_KEY_BASE_REF, GITHUB_TOKEN_REF; aws-ssm:/file: work too) and remove the inline " <>
              "value. See docs/secrets-at-rest.md.",
          meta: %{secrets: report(entries)}
        }
    end
  end

  defp na do
    %Result{
      name: @name,
      status: :na,
      detail: "no service env file (<data-home>/arbiter.env) on this host"
    }
  end

  # Names, states and reference schemes only — never a value.
  defp report(entries) do
    Enum.map(entries, &%{name: &1.name, state: to_string(&1.state), scheme: &1.scheme})
  end
end
