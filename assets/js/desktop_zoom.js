const ZOOM_LEVELS = [0.5, 0.67, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2]
const DEFAULT_ZOOM_INDEX = ZOOM_LEVELS.indexOf(1)
const STORAGE_KEY = "armchair-metropolist:desktop-zoom"
let currentZoomIndex = DEFAULT_ZOOM_INDEX

const restoredZoomIndex = () => {
  try {
    const storedZoom = Number(window.localStorage.getItem(STORAGE_KEY))
    const storedIndex = ZOOM_LEVELS.indexOf(storedZoom)

    return storedIndex === -1 ? currentZoomIndex : storedIndex
  } catch (_error) {
    // A locked-down webview may deny storage access. Zoom should still work for
    // the rest of that process, which is what `currentZoomIndex` preserves.
    return currentZoomIndex
  }
}

const persistZoom = zoom => {
  try {
    window.localStorage.setItem(STORAGE_KEY, String(zoom))
  } catch (_error) {
    // Keep zoom usable when persistence is unavailable.
  }
}

export const DesktopZoom = {
  mounted() {
    const webviewApi = window.__TAURI__?.webview

    // The same LiveView also runs in ordinary browsers. Keep the controls out of
    // that header: browser chrome already owns page zoom, and the Tauri API is not
    // present there.
    if (!webviewApi?.getCurrentWebview) return

    this.zoomIndex = restoredZoomIndex()
    currentZoomIndex = this.zoomIndex
    this.value = this.el.querySelector("[data-zoom-value]")
    this.zoomOut = this.el.querySelector('[data-zoom-action="out"]')
    this.zoomIn = this.el.querySelector('[data-zoom-action="in"]')

    this.handleClick = event => {
      const action = event.target.closest("[data-zoom-action]")?.dataset.zoomAction
      if (action) this.setZoom(action)
    }

    this.handleKeydown = event => {
      if (!(event.metaKey || event.ctrlKey) || event.altKey) return

      let action

      if (event.key === "-") {
        action = "out"
      } else if (event.key === "=" || event.key === "+") {
        action = "in"
      } else if (event.key === "0") {
        action = "reset"
      } else {
        return
      }

      event.preventDefault()
      this.setZoom(action)
    }

    this.el.addEventListener("click", this.handleClick)
    window.addEventListener("keydown", this.handleKeydown)
    this.el.classList.remove("hidden")
    this.el.classList.add("flex")
    this.applyZoom()
  },

  destroyed() {
    if (!this.handleClick) return

    this.el.removeEventListener("click", this.handleClick)
    window.removeEventListener("keydown", this.handleKeydown)
  },

  setZoom(action) {
    if (action === "reset") {
      this.zoomIndex = DEFAULT_ZOOM_INDEX
    } else if (action === "in") {
      this.zoomIndex = Math.min(this.zoomIndex + 1, ZOOM_LEVELS.length - 1)
    } else if (action === "out") {
      this.zoomIndex = Math.max(this.zoomIndex - 1, 0)
    }

    const zoom = ZOOM_LEVELS[this.zoomIndex]
    currentZoomIndex = this.zoomIndex
    persistZoom(zoom)
    this.applyZoom()
  },

  applyZoom() {
    const zoom = ZOOM_LEVELS[this.zoomIndex]

    // WKWebView can accept Tauri's native setZoom command without changing the
    // rendered page. CSS zoom operates on the document itself, so it scales the
    // same text, spacing and fixed-size game elements on every desktop webview.
    if (zoom === 1) {
      document.documentElement.style.removeProperty("zoom")
    } else {
      document.documentElement.style.setProperty("zoom", String(zoom))
    }

    this.updateControls()
  },

  updateControls() {
    this.value.textContent = `${Math.round(ZOOM_LEVELS[this.zoomIndex] * 100)}%`
    this.zoomOut.disabled = this.zoomIndex === 0
    this.zoomIn.disabled = this.zoomIndex === ZOOM_LEVELS.length - 1
  },
}
