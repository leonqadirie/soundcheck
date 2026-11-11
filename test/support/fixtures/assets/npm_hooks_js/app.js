import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import NpmHooks from "npm-hooks"

new LiveSocket("/live", Socket, {hooks: NpmHooks})
