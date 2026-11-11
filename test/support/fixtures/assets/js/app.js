import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/my_app"
import Extra from "./hooks/extra"

const Hooks = {
  InfiniteScroll: {
    mounted() {
      this.pushEvent("load-more", {})
    }
  },
}

Hooks.Chart = {
  mounted() {
    this.pushEventTo(this.el, "zoom", {})
  }
}

new LiveSocket("/live", Socket, {hooks: {...colocatedHooks, ...Hooks, ...Extra}})
