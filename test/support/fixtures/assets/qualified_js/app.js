import * as hooks from "./hooks"
import Base from "./base"

Base.Assigned = {
  mounted() {
    this.pushEvent("assigned-ready", {})
  }
}

new Phoenix.LiveView.LiveSocket("/live", Phoenix.Socket, {hooks: {...hooks, ...Base}})
