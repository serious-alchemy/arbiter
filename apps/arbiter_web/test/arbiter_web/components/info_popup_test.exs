defmodule ArbiterWeb.InfoPopupTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import ArbiterWeb.CoreComponents.Core, only: [info_popup: 1]

  defp render_popup(extra \\ []) do
    assigns = Map.new(extra)

    rendered_to_string(~H"""
    <.info_popup id="pop" label="Why it is 3" {assigns}>
      <:trigger>3</:trigger>
      Because of the workspace setting.
    </.info_popup>
    """)
  end

  test "the trigger is a labelled button that reports and controls the panel" do
    html = render_popup()

    assert html =~ ~s(id="pop-trigger")
    assert html =~ ~s(type="button")
    assert html =~ ~s(aria-label="Why it is 3")
    assert html =~ ~s(aria-expanded="false")
    assert html =~ ~s(aria-controls="pop-panel")
  end

  test "the panel shows on hover, keyboard focus and tap, and is dismissible" do
    html = render_popup()

    assert html =~ ~s(id="pop-panel")
    assert html =~ "Because of the workspace setting."
    assert html =~ "group-hover/pop:block"
    assert html =~ "group-has-[:focus-visible]/pop:block"
    assert html =~ "group-has-[[aria-expanded=true]]/pop:block"
    # tap toggles aria-expanded client-side; Escape and a click away close it
    assert html =~ "phx-click"
    assert html =~ "phx-click-away"
    assert html =~ "Escape"
  end

  test "align=end hangs the panel from its right edge" do
    assert render_popup(align: "end") =~ "right-0"
    assert render_popup() =~ "left-0"
  end
end
