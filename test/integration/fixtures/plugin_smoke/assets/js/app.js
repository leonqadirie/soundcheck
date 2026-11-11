import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"

const Hooks = {}

Hooks.Unused = {
  mounted() {}
}

new LiveSocket("/live", Socket, {hooks: Hooks})
