export default class Connection {
  constructor(hook) {
    this.hook = hook
  }

  archive() {
    this.hook.pushEvent("archive", {})
  }
}
