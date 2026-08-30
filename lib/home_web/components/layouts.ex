defmodule HomeWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use HomeWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :active_nav, :atom,
    default: nil,
    values: [nil, :overview, :router, :secrets, :services, :providers, :requests, :policies]

  attr :secret_count, :integer, default: 0

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="home-shell">
      <input id="home-nav-toggle" type="checkbox" class="home-nav-toggle" />
      <aside id="home-sidebar" class="home-sidebar">
        <.app_header
          href={~p"/"}
          image_src={~p"/images/home-core-mark.png"}
          title="HOME//CORE"
          subtitle="Local command v0.1"
          aria-label="Home dashboard"
        />

        <div class="home-system-line">
          <span><i class="cyber-status-dot online"></i>systems nominal</span>
          <span>SEC:LOCAL</span>
        </div>

        <nav class="home-nav" aria-label="Home applications">
          <.nav_item
            href={~p"/"}
            icon="hero-command-line"
            label="Overview"
            active={@active_nav == :overview}
            class="home-nav-item"
          />
          <.nav_label label="Applications" class="home-nav-label" />
          <.nav_item
            href={~p"/router"}
            icon="hero-arrows-right-left"
            label="LLM Router"
            active={@active_nav == :router}
            meta="01"
            class="home-nav-item"
          />
          <.nav_item
            href={~p"/crypto-keys"}
            icon="hero-key"
            label="Crypto Keys"
            active={@active_nav == :secrets}
            meta={integer_label(@secret_count)}
            class="home-nav-item"
          />
          <.nav_item
            href={~p"/services"}
            icon="hero-signal"
            label="Services"
            active={@active_nav == :services}
            meta="05"
            class="home-nav-item"
          />
          <.nav_label label="Router Intel" class="home-nav-label" />
          <.nav_item
            href={~p"/providers"}
            icon="hero-cube-transparent"
            label="Providers"
            active={@active_nav == :providers}
            class="home-nav-item"
          />
          <.nav_item
            href={~p"/requests"}
            icon="hero-document-text"
            label="Request Log"
            active={@active_nav == :requests}
            class="home-nav-item"
          />
          <.nav_item
            href={~p"/policies"}
            icon="hero-shield-check"
            label="Policies"
            active={@active_nav == :policies}
            class="home-nav-item"
          />
        </nav>

        <footer class="home-sidebar-footer">
          <span class="home-ticker">SYS::ACTIVE</span>
          <div><span>Gateway</span><strong>18ms</strong></div>
          <div><span>localhost:4070</span><span>v0.1.0</span></div>
        </footer>
      </aside>

      <div class="home-viewport">
        <header class="home-mobile-header">
          <label for="home-nav-toggle" class="cyber-icon-button" aria-label="Open navigation">
            <.icon name="hero-bars-3" class="size-4" />
          </label>
          <span>HOME//CORE</span>
          <i class="cyber-status-dot online"></i>
        </header>
        <main id="home-main" class="home-main">{render_slot(@inner_block)}</main>
      </div>
      <label for="home-nav-toggle" class="home-nav-overlay" aria-label="Close navigation"></label>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  defp integer_label(value), do: value |> Integer.to_string() |> String.pad_leading(2, "0")
end
