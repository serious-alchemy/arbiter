System.delete_env("ARBITER_WORKTREE_ROOT")
System.delete_env("ARBITER_OUTPUT_LOG_ROOT")
System.delete_env("ARBITER_MEMORY_ROOT")
System.delete_env("ARB_TOKEN")
System.delete_env("ARB_WORKSPACE")

# Never let a test exec `mix`, `systemctl`, `lsof` or `kill` for real through
# `ArbiterCli.Cmd.Start.run_cmd/3`: an unstubbed restart test once killed the
# live coordinator's server from a worker (bd-asawcq).
Application.put_env(:arbiter_cli, :forbid_real_cmds, true)

ExUnit.start(exclude: [:escript_build])

# Make sure :req's transitive apps (finch, mint, etc.) are started for tests
# that hit the Req.Test plug adapter.
{:ok, _} = Application.ensure_all_started(:req)
