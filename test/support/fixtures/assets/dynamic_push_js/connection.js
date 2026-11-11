export default class Connection {
  constructor(hook, event) {
    this.hook = hook
    this.event = event
  }

  send() {
    this.hook.pushEvent(this.event, {})
  }
}
