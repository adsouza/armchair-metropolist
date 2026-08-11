const STORAGE_KEY = "armchair-metropolist:audio-enabled"
const DEFAULT_ENABLED = true

const readPreference = () => {
  try {
    const stored = window.localStorage.getItem(STORAGE_KEY)
    return stored === null ? DEFAULT_ENABLED : stored === "true"
  } catch (_error) {
    return DEFAULT_ENABLED
  }
}

const savePreference = enabled => {
  try {
    window.localStorage.setItem(STORAGE_KEY, String(enabled))
  } catch (_error) {
    // Audio still works for this session when storage is unavailable.
  }
}

class CityAudio {
  constructor() {
    this.enabled = readPreference()
    this.context = null
    this.masterGain = null
    this.musicGain = null
    this.effectsGain = null
    this.musicTimer = null
    this.nextMeasureAt = 0
    this.measure = 0
    this.lastCueAt = new Map()
  }

  supported() {
    return Boolean(window.AudioContext || window.webkitAudioContext)
  }

  async activate() {
    if (!this.enabled || document.hidden || !this.supported()) return

    if (!this.ensureGraph()) return

    if (this.context.state === "suspended") {
      try {
        await this.context.resume()
      } catch (_error) {
        return
      }
    }

    if (this.context.state !== "running") return

    const now = this.context.currentTime
    this.masterGain.gain.cancelScheduledValues(now)
    this.masterGain.gain.setValueAtTime(Math.max(this.masterGain.gain.value, 0.0001), now)
    this.masterGain.gain.linearRampToValueAtTime(0.35, now + 0.18)
    this.startMusic()
  }

  setEnabled(enabled) {
    this.enabled = enabled
    savePreference(enabled)

    if (enabled) {
      this.activate()
    } else {
      this.stopMusic()
      this.fadeMasterOut()
    }
  }

  ensureGraph() {
    if (this.context) return true

    const AudioContext = window.AudioContext || window.webkitAudioContext

    try {
      this.context = new AudioContext()
      this.masterGain = this.context.createGain()
      this.musicGain = this.context.createGain()
      this.effectsGain = this.context.createGain()

      this.masterGain.gain.value = 0.0001
      this.musicGain.gain.value = 0.4
      this.effectsGain.gain.value = 0.7

      this.musicGain.connect(this.masterGain)
      this.effectsGain.connect(this.masterGain)
      this.masterGain.connect(this.context.destination)
      return true
    } catch (_error) {
      if (this.context) this.context.close()
      this.context = null
      return false
    }
  }

  fadeMasterOut() {
    if (!this.context) return

    const now = this.context.currentTime
    this.masterGain.gain.cancelScheduledValues(now)
    this.masterGain.gain.setValueAtTime(Math.max(this.masterGain.gain.value, 0.0001), now)
    this.masterGain.gain.exponentialRampToValueAtTime(0.0001, now + 0.12)
  }

  startMusic() {
    if (this.musicTimer || !this.enabled || this.context.state !== "running") return

    this.nextMeasureAt = this.context.currentTime + 0.08
    this.scheduleMusic()
    this.musicTimer = window.setInterval(() => this.scheduleMusic(), 800)
  }

  stopMusic() {
    if (!this.musicTimer) return

    window.clearInterval(this.musicTimer)
    this.musicTimer = null
  }

  scheduleMusic() {
    if (!this.enabled || document.hidden || this.context.state !== "running") return

    while (this.nextMeasureAt < this.context.currentTime + 1.2) {
      this.scheduleMeasure(this.nextMeasureAt, this.measure)
      this.nextMeasureAt += 4
      this.measure = (this.measure + 1) % 4
    }
  }

  scheduleMeasure(start, measure) {
    // A slow D-major progression: civic, optimistic, and quiet enough to sit under play.
    const chords = [
      [146.83, 185.00, 220.00],
      [130.81, 164.81, 220.00],
      [110.00, 146.83, 185.00],
      [123.47, 146.83, 196.00],
    ]
    const melodies = [
      [293.66, 369.99, 440.00],
      [329.63, 369.99, 440.00],
      [293.66, 369.99, 440.00],
      [293.66, 392.00, 369.99],
    ]

    for (const frequency of chords[measure]) {
      this.tone(frequency, start, 4.35, 0.026, "sine", null, this.musicGain)
    }

    melodies[measure].forEach((frequency, index) => {
      this.tone(frequency, start + [0.3, 1.65, 2.9][index], 0.65, 0.035, "triangle", null, this.musicGain)
    })
  }

  playCue(cue) {
    if (!this.enabled || !this.context || this.context.state !== "running" || document.hidden) {
      return
    }

    const now = this.context.currentTime
    const lastPlayed = this.lastCueAt.get(cue) || -Infinity

    // Quick start places five blocks at once. One construction cue reads as a result;
    // five simultaneous copies read as clipping.
    if (now - lastPlayed < 0.12) return
    this.lastCueAt.set(cue, now)

    switch (cue) {
      case "build":
        this.tone(220, now, 0.13, 0.16, "triangle", 330)
        this.tone(440, now + 0.07, 0.11, 0.09, "sine", 520)
        break
      case "demolish":
        this.noise(now, 0.16, 0.11)
        this.tone(150, now, 0.23, 0.13, "sawtooth", 55)
        break
      case "expand":
        Array.of(293.66, 369.99, 440).forEach((frequency, index) => {
          this.tone(frequency, now + index * 0.08, 0.24, 0.12, "triangle")
        })
        break
      case "fund":
        this.tone(659.25, now, 0.32, 0.11, "sine")
        this.tone(880, now + 0.1, 0.42, 0.1, "sine")
        break
      case "start":
        Array.of(220, 293.66, 440).forEach((frequency, index) => {
          this.tone(frequency, now + index * 0.1, 0.3, 0.13, "triangle")
        })
        break
      case "decision":
        this.tone(246.94, now, 0.18, 0.11, "triangle")
        this.tone(329.63, now + 0.09, 0.28, 0.12, "triangle")
        break
      case "reset":
        Array.of(329.63, 246.94, 164.81).forEach((frequency, index) => {
          this.tone(frequency, now + index * 0.08, 0.28, 0.1, "sine")
        })
        break
      case "unlock":
        Array.of(523.25, 659.25, 783.99).forEach((frequency, index) => {
          this.tone(frequency, now + index * 0.09, 0.38, 0.1, "sine")
        })
        break
      case "warning":
        this.tone(174.61, now, 0.28, 0.12, "triangle")
        this.tone(174.61, now + 0.36, 0.28, 0.1, "triangle")
        break
      case "collapse":
        this.tone(130.81, now, 0.75, 0.15, "sawtooth", 65.41)
        this.tone(98, now + 0.18, 0.85, 0.11, "sine", 49)
        break
      default:
        break
    }
  }

  tone(frequency, start, duration, volume, type, glideTo = null, destination = this.effectsGain) {
    const oscillator = this.context.createOscillator()
    const envelope = this.context.createGain()

    oscillator.type = type
    oscillator.frequency.setValueAtTime(frequency, start)
    if (glideTo) oscillator.frequency.exponentialRampToValueAtTime(glideTo, start + duration)

    envelope.gain.setValueAtTime(0.0001, start)
    envelope.gain.exponentialRampToValueAtTime(volume, start + Math.min(0.04, duration / 3))
    envelope.gain.exponentialRampToValueAtTime(0.0001, start + duration)

    oscillator.connect(envelope)
    envelope.connect(destination)
    oscillator.start(start)
    oscillator.stop(start + duration + 0.02)
  }

  noise(start, duration, volume) {
    const frameCount = Math.ceil(this.context.sampleRate * duration)
    const buffer = this.context.createBuffer(1, frameCount, this.context.sampleRate)
    const samples = buffer.getChannelData(0)

    for (let index = 0; index < samples.length; index += 1) {
      samples[index] = Math.random() * 2 - 1
    }

    const source = this.context.createBufferSource()
    const filter = this.context.createBiquadFilter()
    const envelope = this.context.createGain()

    filter.type = "lowpass"
    filter.frequency.value = 650
    envelope.gain.setValueAtTime(volume, start)
    envelope.gain.exponentialRampToValueAtTime(0.0001, start + duration)

    source.buffer = buffer
    source.connect(filter)
    filter.connect(envelope)
    envelope.connect(this.effectsGain)
    source.start(start)
  }

  destroy() {
    this.stopMusic()
    if (this.context) this.context.close()
  }
}

export const GameAudio = {
  mounted() {
    this.audio = new CityAudio()
    this.audioOn = this.el.querySelector("[data-audio-on]")
    this.audioOff = this.el.querySelector("[data-audio-off]")

    this.handleToggle = () => {
      this.audio.setEnabled(!this.audio.enabled)
      this.updateControl()
    }

    this.unlockFromInteraction = event => {
      if (event.target instanceof Element && event.target.closest("#game-audio-toggle")) return
      this.audio.activate()
    }

    this.handleVisibility = () => {
      if (document.hidden) {
        this.audio.stopMusic()
        this.audio.fadeMasterOut()
      } else {
        this.audio.activate()
      }
    }

    this.el.addEventListener("click", this.handleToggle)
    document.addEventListener("pointerdown", this.unlockFromInteraction, true)
    document.addEventListener("keydown", this.unlockFromInteraction, true)
    document.addEventListener("visibilitychange", this.handleVisibility)
    this.handleEvent("game-sound", ({cue}) => this.audio.playCue(cue))
    this.updateControl()
  },

  destroyed() {
    this.el.removeEventListener("click", this.handleToggle)
    document.removeEventListener("pointerdown", this.unlockFromInteraction, true)
    document.removeEventListener("keydown", this.unlockFromInteraction, true)
    document.removeEventListener("visibilitychange", this.handleVisibility)
    this.audio.destroy()
  },

  updateControl() {
    const enabled = this.audio.enabled
    const action = enabled ? "Mute music and sound effects" : "Turn on music and sound effects"

    this.el.disabled = !this.audio.supported()
    this.el.dataset.audioState = enabled ? "on" : "off"
    this.el.setAttribute("aria-pressed", String(enabled))
    this.el.setAttribute("aria-label", this.audio.supported() ? action : "Audio is unavailable")
    this.el.title = this.audio.supported() ? action : "Audio is unavailable in this browser"
    this.audioOn.classList.toggle("hidden", !enabled)
    this.audioOff.classList.toggle("hidden", enabled)
  },
}
