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
        <.link navigate={~p"/"} class="home-brand" aria-label="Home dashboard">
          <span class="home-brand-mark">H</span>
          <span><strong>HOME//CORE</strong><small>Local command v0.1</small></span>
        </.link>

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
          />
          <div class="home-nav-label"><span>Applications</span></div>
          <.nav_item
            href={~p"/router"}
            icon="hero-arrows-right-left"
            label="LLM Router"
            active={@active_nav == :router}
            meta="01"
          />
          <.nav_item
            href={~p"/crypto-keys"}
            icon="hero-key"
            label="Crypto Keys"
            active={@active_nav == :secrets}
            meta={integer_label(@secret_count)}
          />
          <.nav_item
            href={~p"/services"}
            icon="hero-signal"
            label="Services"
            active={@active_nav == :services}
            meta="05"
          />
          <div class="home-nav-label"><span>Router Intel</span></div>
          <.nav_item
            href={~p"/providers"}
            icon="hero-cube-transparent"
            label="Providers"
            active={@active_nav == :providers}
          />
          <.nav_item
            href={~p"/requests"}
            icon="hero-document-text"
            label="Request Log"
            active={@active_nav == :requests}
          />
          <.nav_item
            href={~p"/policies"}
            icon="hero-shield-check"
            label="Policies"
            active={@active_nav == :policies}
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

  attr :href, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :active, :boolean, default: false
  attr :meta, :string, default: nil

  defp nav_item(assigns) do
    ~H"""
    <.link navigate={@href} class={["home-nav-item", @active && "is-active"]}>
      <.icon name={@icon} class="size-4" />
      <span>{@label}</span>
      <small :if={@meta}>{@meta}</small>
    </.link>
    """
  end

  defp integer_label(value), do: value |> Integer.to_string() |> String.pad_leading(2, "0")

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
