// WorkerSocket — single WebSocket connection to the Carbide2 worker
// Protocol: { cs, cmd, payload }
// Usage: import workerSocket from './workerSocket'
//        workerSocket.connect(token)
//        workerSocket.on('term', 'output', handler)
//        workerSocket.send('chat', 'message', { text: 'hello' })

const getWorkerUrl = () => {
  if (import.meta.env.VITE_WORKER_URL) return import.meta.env.VITE_WORKER_URL
  const host = window.location.hostname
  return `ws://${host}:8080`
}

class WorkerSocket {
  constructor() {
    this._ws       = null
    this._handlers = {}  // { "cs:cmd": [fn, ...] }
    this._ready    = false
    this._queue    = []
    this._generation = 0  // incremented on each connect() to ignore stale close events
  }

  connect(token) {
    // Close old socket WITHOUT letting its onclose reset _ready for the new one
    if (this._ws) {
      const old = this._ws
      old.onclose = null
      old.onerror = null
      old.close()
    }

    const gen = ++this._generation
    const url = `${getWorkerUrl()}/?token=${encodeURIComponent(token)}`
    console.log('[WorkerSocket] connecting to', url.replace(/token=.*/, 'token=…'))
    this._ws = new WebSocket(url)

    this._ws.onopen = () => {
      if (this._generation !== gen) return  // stale
      console.log('[WorkerSocket] connected')
      this._ready = true
      this._queue.forEach(m => this._ws.send(m))
      this._queue = []
    }

    this._ws.onmessage = (event) => {
      if (this._generation !== gen) return
      let msg
      try { msg = JSON.parse(event.data) } catch { return }
      console.debug('[WorkerSocket] ←', msg.cs, msg.cmd, msg.payload)
      const key = `${msg.cs}:${msg.cmd}`
      const handlers = this._handlers[key] || []
      const wildcards = this._handlers[`${msg.cs}:*`] || []
      ;[...handlers, ...wildcards].forEach(fn => fn(msg.payload, msg))
    }

    this._ws.onclose = (e) => {
      if (this._generation !== gen) return
      console.warn('[WorkerSocket] closed', e.code, e.reason)
      this._ready = false
    }

    this._ws.onerror = (e) => {
      if (this._generation !== gen) return
      console.error('[WorkerSocket] error', e)
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
      console.debug('[WorkerSocket] →', cs, cmd, payload)
      this._ws.send(msg)
    } else {
      console.warn('[WorkerSocket] not ready, queuing', cs, cmd)
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
