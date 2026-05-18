// WorkerSocket — single WebSocket connection to the Carbide2 worker
// Protocol: { cs, cmd, payload }
// Usage: import workerSocket from './workerSocket'
//        workerSocket.connect(token)
//        workerSocket.on('term', 'output', handler)
//        workerSocket.send('chat', 'message', { text: 'hello' })

const WORKER_URL = import.meta.env.VITE_WORKER_URL || 'ws://localhost:8080'

class WorkerSocket {
  constructor() {
    this._ws       = null
    this._handlers = {}  // { "cs:cmd": [fn, ...] }
    this._ready    = false
    this._queue    = []
  }

  connect(token) {
    if (this._ws) this._ws.close()

    this._ws = new WebSocket(`${WORKER_URL}/?token=${encodeURIComponent(token)}`)

    this._ws.onopen = () => {
      this._ready = true
      this._queue.forEach(m => this._ws.send(m))
      this._queue = []
    }

    this._ws.onmessage = (event) => {
      let msg
      try { msg = JSON.parse(event.data) } catch { return }
      const key = `${msg.cs}:${msg.cmd}`
      const handlers = this._handlers[key] || []
      const wildcards = this._handlers[`${msg.cs}:*`] || []
      ;[...handlers, ...wildcards].forEach(fn => fn(msg.payload, msg))
    }

    this._ws.onclose = () => {
      this._ready = false
    }

    this._ws.onerror = (e) => {
      console.error('WorkerSocket error', e)
    }
  }

  disconnect() {
    this._ws?.close()
    this._ws    = null
    this._ready = false
    this._queue = []
  }

  send(cs, cmd, payload = {}) {
    const msg = JSON.stringify({ cs, cmd, payload })
    if (this._ready) {
      this._ws.send(msg)
    } else {
      this._queue.push(msg)
    }
  }

  on(cs, cmd, fn) {
    const key = `${cs}:${cmd}`
    if (!this._handlers[key]) this._handlers[key] = []
    this._handlers[key].push(fn)
    return () => this.off(cs, cmd, fn)
  }

  off(cs, cmd, fn) {
    const key = `${cs}:${cmd}`
    if (!this._handlers[key]) return
    this._handlers[key] = this._handlers[key].filter(h => h !== fn)
  }

  get connected() {
    return this._ws?.readyState === WebSocket.OPEN
  }
}

// Singleton — one connection per project session
export default new WorkerSocket()
