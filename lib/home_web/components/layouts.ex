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
    <.app_shell
      id="home-shell"
      main_id="home-main"
      sidebar_id="home-sidebar"
      mobile_title="HOME//CORE"
      main_class="home-main w-full max-w-[1600px] min-h-screen mx-auto p-4 lg:p-6"
    >
      <:mobile_actions>
        <i class="cyber-status-dot online"></i>
      </:mobile_actions>

      <:sidebar_header>
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
      </:sidebar_header>

      <:sidebar_nav>
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
      </:sidebar_nav>

      <:sidebar_footer>
        <footer class="home-sidebar-footer">
          <span class="home-ticker">SYS::ACTIVE</span>
          <.theme_toggle />
          <div><span>Gateway</span><strong>18ms</strong></div>
          <div><span>localhost:4070</span><span>v0.1.0</span></div>
        </footer>
      </:sidebar_footer>

      {render_slot(@inner_block)}
    </.app_shell>

    <.flash_group flash={@flash} />
    """
  end

  defp integer_label(value), do: value |> Integer.to_string() |> String.pad_leading(2, "0")
end
