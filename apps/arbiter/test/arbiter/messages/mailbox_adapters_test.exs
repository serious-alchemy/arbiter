defmodule Arbiter.Messages.MailboxAdaptersTest do
  use ExUnit.Case, async: true

  # P-26 AC4: every mailbox surface goes through `Arbiter.Messages.Mailbox`.
  # The CLI has no domain access — it drives REST, so REST is its adapter.
  @adapters [
    "apps/arbiter_web/lib/arbiter_web/controllers/api/message_controller.ex",
    "apps/arbiter/lib/arbiter/mcp/tools/messaging.ex"
  ]

  @root Path.expand("../../../../..", __DIR__)

  for adapter <- @adapters do
    test "#{adapter} calls the shared Mailbox API" do
      source = File.read!(Path.join(@root, unquote(adapter)))
      assert source =~ "Mailbox.list("
      assert source =~ "Mailbox.clear("
      assert source =~ "Mailbox.reader("
    end
  end

  test "REST and MCP both send and list notifications through the same functions" do
    rest = File.read!(Path.join(@root, hd(@adapters)))
    mcp = File.read!(Path.join(@root, List.last(@adapters)))

    assert rest =~ "Mailbox.send_message("
    assert mcp =~ "Mailbox.send_message("
    assert mcp =~ "Mailbox.notifications("
    assert rest =~ "Mailbox.list("
  end
end
