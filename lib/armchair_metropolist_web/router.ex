defmodule ArmchairMetropolistWeb.Router do
  use ArmchairMetropolistWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug ArmchairMetropolistWeb.Plugs.EnsureCityId
    plug :fetch_live_flash
    plug :put_root_layout, html: {ArmchairMetropolistWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    # After :put_secure_browser_headers, which sets the other security headers but
    # no CSP. Separate plug because the policy carries a per-request nonce and so
    # cannot be the static map that plug takes.
    plug :put_content_security_policy
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", ArmchairMetropolistWeb do
    pipe_through :browser

    live "/", SimulatorLive
  end

  # Other scopes may use custom stacks.
  # scope "/api", ArmchairMetropolistWeb do
  #   pipe_through :api
  # end

  # Sets a Content-Security-Policy with a fresh nonce per request, which the root
  # layout puts on its one inline `<script>` (the theme setter, which cannot be
  # deferred to app.js without a flash of the wrong theme).
  #
  # A nonce rather than `script-src 'unsafe-inline'`: inline script is the exact
  # thing `script-src` exists to stop, so allowing it wholesale would leave a header
  # that looks protective while permitting the attack it is named for.
  defp put_content_security_policy(conn, _opts) do
    nonce = 18 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    conn
    |> assign(:csp_nonce, nonce)
    |> put_resp_header("content-security-policy", content_security_policy(nonce))
  end

  defp content_security_policy(nonce) do
    [
      "default-src 'self'",
      "script-src 'self' 'nonce-#{nonce}'",
      # `'unsafe-inline'` here is deliberate and load-bearing: the grid positions
      # every cell with an inline `style` attribute computed from its coordinates,
      # which this directive governs. Far weaker consequences than the script case —
      # injected CSS cannot execute — and the alternative is a nonce per cell.
      "style-src 'self' 'unsafe-inline'",
      # `data:` covers the inlined SVG favicon and any data-URI image.
      "img-src 'self' data:",
      "font-src 'self'",
      # Same-origin only, which includes this origin's WebSocket for the LiveView
      # socket — no third-party telemetry or CDN to allow.
      "connect-src 'self'",
      "frame-ancestors 'none'",
      "base-uri 'self'",
      "object-src 'none'"
    ]
    |> Enum.join("; ")
  end
end
