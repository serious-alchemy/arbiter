defmodule ArbiterWeb.PageController do
  use ArbiterWeb, :controller

  def home(conn, _params) do
    render(conn, :home,
      issues_label: "Tickets",
      workers_label: "Workers",
      domains_label: "Workspaces",
      app_version: Arbiter.Version.app_version(),
      git_sha: Arbiter.Version.git_sha(),
      update: Arbiter.Release.UpdateCheck.state()
    )
  end
end
