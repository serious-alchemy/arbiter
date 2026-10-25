defmodule Arbiter.Worker.Image.KnownHostsTest do
  use ExUnit.Case, async: true

  alias Arbiter.Worker.Image
  alias Arbiter.Worker.Image.KnownHosts

  # The fingerprints GitLab and GitHub publish for their ED25519 host keys.
  @gitlab "SHA256:eUXGGm1YGsMAS7vkcx6JOJdOGHPem5gQp4taiCfCLB8"
  @github "SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU"

  @tag :tmp_dir
  test "pinned keys carry the published fingerprints", %{tmp_dir: dir} do
    path = Path.join(dir, "ssh_known_hosts")
    File.write!(path, KnownHosts.file_content())

    {out, 0} = System.cmd("ssh-keygen", ["-lf", path])
    assert out =~ "#{@gitlab} gitlab.com (ED25519)"
    assert out =~ "#{@github} github.com (ED25519)"
  end

  @tag :tmp_dir
  test "ssh verifies against the pinned file without disabling host key checking", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "ssh_known_hosts")
    File.write!(path, KnownHosts.file_content())

    for host <- ["gitlab.com", "github.com"] do
      {out, 0} =
        System.cmd("ssh", [
          "-G",
          "-F",
          "/dev/null",
          "-o",
          "GlobalKnownHostsFile=#{path}",
          "-o",
          "UserKnownHostsFile=/dev/null",
          host
        ])

      assert out =~ "globalknownhostsfile #{path}"
      refute out =~ ~r/stricthostkeychecking (false|no|off|accept-new)/
      {_, 0} = System.cmd("ssh-keygen", ["-F", host, "-f", path])
    end
  end

  test "the worker base image installs the pins as the system known_hosts, strictly" do
    cf = Image.base_containerfile(System.otp_release())

    assert cf =~ "/etc/ssh/ssh_known_hosts"
    assert cf =~ "gitlab.com ssh-ed25519 "
    assert cf =~ "github.com ssh-ed25519 "
    refute cf =~ "StrictHostKeyChecking"
    refute cf =~ "accept-new"
    refute cf =~ "ssh-keyscan"
  end
end
