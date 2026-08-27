defmodule HomeWeb.CryptoKeysLiveTest do
  use HomeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Home.Secrets.Store

  test "lists secret metadata without exposing plaintext", %{conn: conn} do
    assert {:ok, secret} =
             Store.put("llm", "TEST_ROUTER_KEY", "never-render-this", description: "test key")

    {:ok, view, html} = live(conn, ~p"/crypto-keys")

    assert has_element?(view, "#secrets-#{secret.id}")
    assert has_element?(view, "#secrets-#{secret.id}[data-state='active']")
    refute html =~ "never-render-this"

    view
    |> element("#toggle-secret-#{secret.id}")
    |> render_click()

    assert has_element?(view, "#secrets-#{secret.id}[data-state='inactive']")
  end

  test "stores a new encrypted key", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/crypto-keys")

    view
    |> element("#new-secret")
    |> render_click()

    view
    |> form("#secret-form",
      secret: %{
        service: "llm",
        key: "NEW_PROVIDER_KEY",
        value: "encrypted-value",
        description: "new provider"
      }
    )
    |> render_submit()

    assert has_element?(view, "#stored-keys")
    assert {:ok, "encrypted-value"} = Store.get("llm", "NEW_PROVIDER_KEY")
  end
end
