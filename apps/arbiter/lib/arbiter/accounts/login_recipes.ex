defmodule Arbiter.Accounts.LoginRecipes do
  @moduledoc """
  The per-provider `Arbiter.Accounts.LoginRecipe` table (login relay,
  bd-dqvv90 / bd-82yxz2). Patterns come from spike bd-29ycw1.

    * `:claude` / `:codex` — enabled.
    * `:grok` — defined but disabled until its adapter exists.
    * `:agy` — explicitly unsupported: no login subcommand, full-screen TUI,
      and `--gemini_dir` did not isolate it (it reused the operator's real
      identity), so there is deliberately no recipe.

  Failure patterns are best-effort: the spike stopped at the human-input
  point, so no real failure output was recorded. Callers must also treat a
  non-zero process exit as failure.
  """

  alias Arbiter.Accounts.LoginRecipe

  @unsupported [:agy]

  @doc "Every defined recipe, enabled or not."
  @spec all() :: [LoginRecipe.t()]
  def all, do: [claude(), codex(), grok()]

  @doc "Only the recipes a login may actually be started with."
  @spec enabled() :: [LoginRecipe.t()]
  def enabled, do: Enum.filter(all(), & &1.enabled?)

  @doc """
  Fetch the recipe for `provider`. `{:error, :unsupported}` for providers
  that can never log in via the relay, `{:error, :disabled}` for defined but
  switched-off ones, `{:error, :unknown}` otherwise.
  """
  @spec fetch(atom()) :: {:ok, LoginRecipe.t()} | {:error, :unsupported | :disabled | :unknown}
  def fetch(provider) when provider in @unsupported, do: {:error, :unsupported}

  def fetch(provider) when is_atom(provider) do
    case Enum.find(all(), &(&1.provider == provider)) do
      nil -> {:error, :unknown}
      %LoginRecipe{enabled?: false} -> {:error, :disabled}
      recipe -> {:ok, recipe}
    end
  end

  @doc "Providers that are explicitly unsupported."
  @spec unsupported() :: [atom()]
  def unsupported, do: @unsupported

  @spec claude() :: LoginRecipe.t()
  def claude do
    %LoginRecipe{
      provider: :claude,
      command: "claude",
      # Paste-code is the default flow; nothing to force. It does NOT exit on
      # stdin EOF — it waits for a line — so the relay must send the code.
      args: ["auth", "login"],
      config_dir_env: "CLAUDE_CONFIG_DIR",
      flow: :paste_code,
      status_command: ["claude", "auth", "status", "--json"],
      status_success: {:json, ["loggedIn"], true},
      # The URL line is an OSC-8 hyperlink; LoginRecipe.strip_ansi/1 unwraps it.
      url_pattern: ~r{(https://claude\.com/cai/oauth/authorize\S+)},
      # Prompt has no trailing newline.
      code_prompt_pattern: ~r/Paste code here if prompted >/,
      device_code_pattern: nil,
      success_pattern: ~r/Login successful\./,
      failure_pattern: ~r/(?:Login failed|Authentication failed|OAuth error|Invalid code)/i,
      credential_path: ".credentials.json"
    }
  end

  @spec codex() :: LoginRecipe.t()
  def codex do
    %LoginRecipe{
      provider: :codex,
      command: "codex",
      # The default is a localhost:1455 callback, useless over the tailnet.
      args: ["login", "--device-auth"],
      config_dir_env: "CODEX_HOME",
      flow: :device_code,
      status_command: ["codex", "login", "status"],
      status_success: {:exit_zero},
      url_pattern: ~r{(https://auth\.openai\.com/codex/device)},
      code_prompt_pattern: nil,
      # The code sits on the line AFTER "Enter this one-time code".
      device_code_pattern:
        ~r/Enter this one-time code[^\n]*\n\s*([A-Z0-9]{3,}(?:-[A-Z0-9]{3,})+)/,
      # Nothing renders while it polls: success is `codex login status` /
      # process exit, never screen text.
      success_pattern: nil,
      failure_pattern: ~r/(?:Login failed|Device code (?:expired|login failed)|expired)/i,
      credential_path: "auth.json"
    }
  end

  @spec grok() :: LoginRecipe.t()
  def grok do
    %LoginRecipe{
      provider: :grok,
      command: "grok",
      args: ["login", "--device-auth"],
      config_dir_env: "GROK_HOME",
      flow: :device_code,
      # No status command exists: fall back to the credential file existing.
      status_command: nil,
      status_success: nil,
      status_fallback_file: "auth.json",
      url_pattern: ~r{(https://accounts\.x\.ai/oauth2/device\S*)},
      code_prompt_pattern: nil,
      device_code_pattern:
        ~r/Confirm this code in your browser:\s*\n\s*([A-Z0-9]{3,}(?:-[A-Z0-9]{3,})+)/,
      # Only a poll line is shown: "Waiting for authorization..."
      success_pattern: nil,
      failure_pattern: ~r/(?:Login failed|expired|denied)/i,
      credential_path: "auth.json",
      enabled?: false
    }
  end
end
