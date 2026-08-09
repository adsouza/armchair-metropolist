defmodule ArmchairMetropolistWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use ArmchairMetropolistWeb, :html

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
        <:actions><button>Reset</button></:actions>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  slot :actions,
    doc: "page controls for the header, rendered beside the theme toggle"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="navbar border-b border-base-200 px-4 sm:px-6 lg:px-8">
      <div class="flex-1">
        <%!-- A two-column grid, not a flex row with a nested column, so the subtitle can
              span the full brand width and share a right edge with the title.

              `min-content` on the second column is load-bearing and `1fr` is the trap:
              `text-right` aligns to the *column box*, and a `1fr` column stretches to fill
              the brand — measured 146px wide at a 375px viewport while the wrapped title
              inked only 82px of it, so right-aligning pushed the subtitle 64px past the
              text it was supposed to line up with. `min-content` sizes the column to the
              longest word, so box edge and ink edge coincide and the alignment is exact at
              both 375 and 1932. It also narrows the brand from 200px to 146px, which hands
              width back to the header rather than spending it.

              The title stays in column 2 beside the logo and wraps to two lines there.
              That is wanted, not tolerated. --%>
        <a
          href="/"
          class="grid w-fit grid-cols-[auto_min-content] items-center gap-x-3 gap-y-0.5"
          aria-label="Armchair Metropolist"
        >
          <.city_mark />
          <span class="text-base font-semibold tracking-tight leading-tight">
            Armchair Metropolist
          </span>
          <span class="col-span-2 text-right text-[11px] opacity-60">
            city infrastructure simulator
          </span>
        </a>
      </div>
      <%!-- `flex` is mandatory here and is not what `flex-none` provides: daisyUI's
            `.flex-none` is `flex: none`, describing how this div behaves as a *child* of
            the navbar, and says nothing about its own children. Without `flex` a second
            control stacks above the theme toggle and grows the header from 64px to 77px at
            every viewport width. --%>
      <div class="flex flex-none items-center gap-2">
        {render_slot(@actions)}
        <.desktop_zoom_controls />
        <.theme_toggle />
      </div>
    </header>

    <main class="px-4 py-8 sm:px-6 lg:px-8">
      <div class="mx-auto w-fit max-w-full space-y-4">
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Browser-style zoom controls for the native desktop webview.

  They render hidden so the web target keeps using its browser chrome. The
  `DesktopZoom` hook reveals and operates them only when Tauri's webview API is
  available.
  """
  def desktop_zoom_controls(assigns) do
    ~H"""
    <div
      id="desktop-zoom-controls"
      phx-hook="DesktopZoom"
      phx-update="ignore"
      class="hidden flex-row items-center overflow-hidden rounded-full border-2 border-base-300 bg-base-100"
      aria-label="Desktop zoom controls"
    >
      <button
        id="desktop-zoom-out"
        type="button"
        data-zoom-action="out"
        class="cursor-pointer p-2 transition-colors hover:bg-base-200 disabled:cursor-not-allowed disabled:opacity-35"
        aria-label="Zoom out"
        title="Zoom out (Command/Ctrl −)"
      >
        <.icon name="hero-minus-micro" class="size-4" />
      </button>
      <button
        id="desktop-zoom-reset"
        type="button"
        data-zoom-action="reset"
        class="min-w-12 cursor-pointer border-x border-base-300 px-2 py-2 text-xs font-semibold tabular-nums transition-colors hover:bg-base-200"
        aria-label="Reset zoom to 100%"
        title="Reset zoom (Command/Ctrl 0)"
      >
        <span data-zoom-value>100%</span>
      </button>
      <button
        id="desktop-zoom-in"
        type="button"
        data-zoom-action="in"
        class="cursor-pointer p-2 transition-colors hover:bg-base-200 disabled:cursor-not-allowed disabled:opacity-35"
        aria-label="Zoom in"
        title="Zoom in (Command/Ctrl +)"
      >
        <.icon name="hero-plus-micro" class="size-4" />
      </button>
    </div>
    """
  end

  @doc """
  The application mark: a grid tile holding four buildings of differing height.

  Deliberately built from the same semantic colours the simulation uses for node
  status — `success` / `warning` / `error` — so the logo reads as a small city in
  mixed health and stays consistent with what the grid itself shows. The frame and
  gridlines use `currentColor`, so the mark themes with the rest of the chrome
  rather than carrying its own palette.
  """
  def city_mark(assigns) do
    ~H"""
    <svg viewBox="0 0 32 32" class="size-9 shrink-0" role="img" aria-hidden="true">
      <rect
        x="1.25"
        y="1.25"
        width="29.5"
        height="29.5"
        rx="5"
        fill="none"
        stroke="currentColor"
        stroke-opacity="0.3"
        stroke-width="1.5"
      />
      <path
        d="M10.75 2.5v27M21.25 2.5v27M2.5 10.75h27M2.5 21.25h27"
        stroke="currentColor"
        stroke-opacity="0.12"
        stroke-width="1"
      />
      <rect x="5" y="19" width="4.5" height="8" rx="1" class="fill-success" />
      <rect x="11.5" y="13" width="4.5" height="14" rx="1" class="fill-success" />
      <rect x="18" y="16" width="4.5" height="11" rx="1" class="fill-warning" />
      <rect x="24.5" y="21" width="3" height="6" rx="1" class="fill-error" />
    </svg>
    """
  end

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
        title="We can't find the internet"
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="Something went wrong!"
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
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
