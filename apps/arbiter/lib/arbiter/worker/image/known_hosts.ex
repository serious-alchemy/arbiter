defmodule Arbiter.Worker.Image.KnownHosts do
  @moduledoc """
  The forge SSH host keys pinned into the worker base image (bd-290vof).

  A container's `HOME` is a fresh per-run directory with no `~/.ssh/known_hosts`,
  and `StrictHostKeyChecking` is left at its default, so `git fetch origin` over
  SSH from a worker container failed with `Host key verification failed` for a
  GitLab or GitHub origin. The base image
  (`Arbiter.Worker.Image.base_containerfile/1`) now writes these to
  `/etc/ssh/ssh_known_hosts`, which ssh reads whatever `-F` config
  `GIT_SSH_COMMAND` names (it is `GlobalKnownHostsFile`, not config), so the
  proxy, deploy-key and bare-`ssh` paths all verify against it. They are pinned,
  never trusted-on-first-use: no `StrictHostKeyChecking=no` and no `accept-new`.

  The ED25519 keys are the ones the forges publish
  (<https://docs.gitlab.com/user/gitlab_com/#ssh-known_hosts-entries>,
  <https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints>);
  the test checks the fingerprints. A forge that rotates its key needs this list
  updated, and the base image rebuilt. A self-hosted forge is not covered.
  """

  @path "/etc/ssh/ssh_known_hosts"

  @entries [
    {"gitlab.com", "ssh-ed25519",
     "AAAAC3NzaC1lZDI1NTE5AAAAIAfuCHKVTjquxvt6CM6tdG4SLp1Btn/nOeHHE5UOzRdf"},
    {"github.com", "ssh-ed25519",
     "AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"}
  ]

  @doc "Where the base image installs the pinned keys."
  @spec path() :: String.t()
  def path, do: @path

  @doc "The `known_hosts` lines, newline-terminated."
  @spec file_content() :: String.t()
  def file_content,
    do: Enum.map_join(@entries, fn {host, type, key} -> "#{host} #{type} #{key}\n" end)

  @doc "A Containerfile `RUN` that writes the pinned keys to `path/0`."
  @spec containerfile_run() :: String.t()
  def containerfile_run do
    echoes =
      Enum.map_join(@entries, " \\\n && ", fn {h, t, k} -> "echo '#{h} #{t} #{k}' >> #{@path}" end)

    "RUN : > #{@path} \\\n && " <> echoes <> " \\\n && chmod 644 #{@path}"
  end
end
