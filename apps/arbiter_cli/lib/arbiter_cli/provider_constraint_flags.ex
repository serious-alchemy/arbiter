defmodule ArbiterCli.ProviderConstraintFlags do
  @moduledoc """
  The per-ticket provider constraint flags (bd-13pqcp), shared by
  `arb ticket create` and `arb ticket update`:

    * `--require-provider <p>` — only these providers may run the ticket's
      implementer;
    * `--exclude-provider <p>` — anything but these may;
    * `--clear-provider-constraint` — (update) drop the constraint.

  Both provider flags repeat and take comma lists (`--exclude-provider agy
  --exclude-provider codex`, or `--exclude-provider agy,codex`). Providers are
  adapter types (`claude`, `gemini`, `codex`); `agy` is accepted as `gemini`.
  A ticket carries one of the two, never both — the server canonicalizes and
  validates, this only refuses the contradiction early. Setting it is
  coordinator/operator authority: a worker token is refused with a 403.
  """

  alias ArbiterCli.Output

  @switches [
    require_provider: [:string, :keep],
    exclude_provider: [:string, :keep],
    clear_provider_constraint: :boolean
  ]

  @doc "The `OptionParser` switches to append to a command's own."
  @spec switches() :: keyword()
  def switches, do: @switches

  @doc """
  The payload entry for the parsed `opts`: `%{}` when no flag was given,
  `%{"provider_constraint" => %{...}}` to set, `%{"provider_constraint" => nil}`
  to clear. Dies on contradictory flags.
  """
  @spec payload(keyword()) :: map()
  def payload(opts) do
    required = values(opts, :require_provider)
    excluded = values(opts, :exclude_provider)
    clear? = opts[:clear_provider_constraint] == true

    cond do
      required != [] and excluded != [] ->
        Output.die("--require-provider and --exclude-provider are mutually exclusive")

      clear? and (required != [] or excluded != []) ->
        Output.die(
          "--clear-provider-constraint cannot be combined with --require-provider / " <>
            "--exclude-provider"
        )

      required != [] ->
        %{"provider_constraint" => %{"require" => required}}

      excluded != [] ->
        %{"provider_constraint" => %{"exclude" => excluded}}

      clear? ->
        %{"provider_constraint" => nil}

      true ->
        %{}
    end
  end

  defp values(opts, key) do
    opts
    |> Keyword.get_values(key)
    |> Enum.flat_map(&String.split(&1, ",", trim: true))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end
end
