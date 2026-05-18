<template>
  <div class="workspace">
    <!-- Header -->
    <header class="workspace-header">
      <span class="project-name">{{ project?.name || 'Loading...' }}</span>
      <button class="btn-secondary" @click="$router.push('/dashboard')">← Dashboard</button>
    </header>

    <div class="workspace-body">
      <!-- Terminal panel -->
      <section class="panel terminal-panel">
        <div class="panel-header">
          <span>Terminal</span>
          <button class="btn-small" @click="openTerminal" :disabled="terminalLoading">
            {{ terminalLoading ? 'Opening...' : terminalActive ? 'New Terminal' : 'Open Terminal' }}
          </button>
        </div>
        <div ref="terminalEl" class="xterm-container"></div>
        <div v-if="!terminalActive" class="panel-placeholder">
          Click "Open Terminal" to start a shell session.
        </div>
      </section>

      <!-- Chat panel -->
      <section class="panel chat-panel">
        <div class="panel-header">
          <span>Chat</span>
          <span class="user-count">{{ chatUsers.length }} online</span>
        </div>

        <div class="chat-messages" ref="chatEl">
          <div v-for="(msg, i) in chatMessages" :key="i" class="chat-msg"
               :class="{ 'chat-msg--own': msg.user_id === currentUserId }">
            <span class="chat-name">{{ msg.name }}</span>
            <span class="chat-text">{{ msg.text }}</span>
            <span class="chat-time">{{ formatTime(msg.timestamp) }}</span>
          </div>
          <div v-if="chatMessages.length === 0" class="panel-placeholder">No messages yet.</div>
        </div>

        <div class="chat-input-row">
          <input
            v-model="chatInput"
            @keydown.enter="sendChat"
            placeholder="Type a message..."
            :disabled="!wsConnected"
            class="chat-input"
          />
          <button class="btn-primary" @click="sendChat" :disabled="!wsConnected || !chatInput.trim()">
            Send
          </button>
        </div>
      </section>
    </div>

    <div v-if="error" class="error-banner">{{ error }}</div>
  </div>
</template>

<script setup>
import { ref, onMounted, onBeforeUnmount, nextTick, computed } from 'vue'
import { useRoute } from 'vue-router'
import { Terminal } from '@xterm/xterm'
import { FitAddon } from '@xterm/addon-fit'
import '@xterm/xterm/css/xterm.css'
import workerSocket from '../services/workerSocket'
import { listProjects, getWsToken, createTerminal } from '../services/projectService'
import authService from '../services/authService'

const route        = useRoute()
const projectId    = Number(route.params.id)
const project      = ref(null)
const error        = ref('')
const wsConnected  = ref(false)

// Terminal
const terminalEl      = ref(null)
const terminalActive  = ref(false)
const terminalLoading = ref(false)
let xterm    = null
let fitAddon = null
let terminalId = null
const offHandlers = []

// Chat
const chatEl       = ref(null)
const chatMessages = ref([])
const chatUsers    = ref([])
const chatInput    = ref('')
const currentUserId = computed(() => authService.userId())

onMounted(async () => {
  try {
    const projects = await listProjects()
    project.value  = projects.find(p => p.id === projectId)

    // Connect WebSocket
    const token = await getWsToken(projectId)
    workerSocket.connect(token)

    offHandlers.push(
      workerSocket.on('system', 'connected', () => {
        wsConnected.value = true
        workerSocket.send('chat', 'join', {})
      })
    )

    // Chat handlers
    offHandlers.push(
      workerSocket.on('chat', 'message', (p) => {
        chatMessages.value.push(p)
        nextTick(() => scrollChat())
      }),
      workerSocket.on('chat', 'user_join', (p) => {
        if (!chatUsers.value.find(u => u.user_id === p.user_id)) {
          chatUsers.value.push({ user_id: p.user_id, name: p.name })
        }
        chatMessages.value.push({ system: true, text: `${p.name} joined`, timestamp: new Date().toISOString() })
        nextTick(() => scrollChat())
      }),
      workerSocket.on('chat', 'user_leave', (p) => {
        chatUsers.value = chatUsers.value.filter(u => u.user_id !== p.user_id)
        chatMessages.value.push({ system: true, text: `${p.name} left`, timestamp: new Date().toISOString() })
      }),
      workerSocket.on('chat', 'user_list', (p) => {
        chatUsers.value = p.users || []
      })
    )

    // Terminal output handler (registered once, filtered by terminalId)
    offHandlers.push(
      workerSocket.on('term', 'output', (p) => {
        if (xterm && p.terminal_id === terminalId) {
          xterm.write(p.data)
        }
      }),
      workerSocket.on('term', 'exit', (p) => {
        if (xterm && p.terminal_id === terminalId) {
          xterm.writeln('\r\n[session ended]')
          terminalActive.value = false
        }
      })
    )
  } catch (e) {
    error.value = e.message || 'Failed to connect'
  }
})

onBeforeUnmount(() => {
  offHandlers.forEach(off => off())
  workerSocket.disconnect()
  xterm?.dispose()
})

async function openTerminal() {
  terminalLoading.value = true
  try {
    const resp = await createTerminal(projectId)
    terminalId = resp.terminal_id

    await nextTick()

    if (!xterm) {
      xterm    = new Terminal({ cursorBlink: true, fontSize: 14, theme: { background: '#1e1e1e' } })
      fitAddon = new FitAddon()
      xterm.loadAddon(fitAddon)
      xterm.open(terminalEl.value)
      fitAddon.fit()

      xterm.onData(data => {
        workerSocket.send('term', 'input', { terminal_id: terminalId, data })
      })

      xterm.onResize(({ cols, rows }) => {
        workerSocket.send('term', 'resize', { terminal_id: terminalId, cols, rows })
      })

      window.addEventListener('resize', () => fitAddon?.fit())
    }

    workerSocket.send('term', 'join', { terminal_id: terminalId })
    terminalActive.value = true
  } catch (e) {
    error.value = e.message || 'Failed to open terminal'
  } finally {
    terminalLoading.value = false
  }
}

function sendChat() {
  const text = chatInput.value.trim()
  if (!text) return
  workerSocket.send('chat', 'message', { text })
  chatInput.value = ''
}

function scrollChat() {
  if (chatEl.value) chatEl.value.scrollTop = chatEl.value.scrollHeight
}

function formatTime(ts) {
  if (!ts) return ''
  return new Date(ts).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })
}
</script>

<style scoped>
.workspace {
  display: flex;
  flex-direction: column;
  height: 100vh;
  background: #1a1a2e;
  color: #e0e0e0;
  font-family: monospace;
}

.workspace-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 0.5rem 1rem;
  background: #16213e;
  border-bottom: 1px solid #0f3460;
}

.project-name { font-size: 1.1rem; font-weight: bold; color: #4fc3f7; }

.workspace-body {
  display: flex;
  flex: 1;
  overflow: hidden;
  gap: 0;
}

.panel {
  display: flex;
  flex-direction: column;
  border: 1px solid #0f3460;
}

.terminal-panel {
  flex: 2;
  border-right: 2px solid #0f3460;
}

.chat-panel {
  flex: 1;
  min-width: 280px;
  max-width: 360px;
}

.panel-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 0.4rem 0.75rem;
  background: #16213e;
  border-bottom: 1px solid #0f3460;
  font-size: 0.85rem;
  font-weight: bold;
  color: #4fc3f7;
}

.xterm-container {
  flex: 1;
  padding: 4px;
  overflow: hidden;
  background: #1e1e1e;
}

.panel-placeholder {
  flex: 1;
  display: flex;
  align-items: center;
  justify-content: center;
  color: #555;
  font-size: 0.85rem;
}

/* Chat */
.chat-messages {
  flex: 1;
  overflow-y: auto;
  padding: 0.5rem;
  display: flex;
  flex-direction: column;
  gap: 0.4rem;
}

.chat-msg {
  display: flex;
  flex-direction: column;
  font-size: 0.82rem;
}

.chat-msg--own .chat-name { color: #4fc3f7; }
.chat-name { color: #aaa; font-weight: bold; margin-bottom: 1px; }
.chat-text { color: #e0e0e0; word-break: break-word; }
.chat-time { color: #555; font-size: 0.7rem; }

.chat-input-row {
  display: flex;
  gap: 0.5rem;
  padding: 0.5rem;
  border-top: 1px solid #0f3460;
}

.chat-input {
  flex: 1;
  background: #111;
  border: 1px solid #0f3460;
  color: #e0e0e0;
  padding: 0.4rem 0.6rem;
  font-family: monospace;
  font-size: 0.85rem;
  border-radius: 3px;
}

.chat-input:focus { outline: none; border-color: #4fc3f7; }

.user-count { color: #4caf50; font-size: 0.75rem; font-weight: normal; }

.btn-small {
  padding: 0.2rem 0.6rem;
  background: #0f3460;
  border: 1px solid #4fc3f7;
  color: #4fc3f7;
  cursor: pointer;
  font-size: 0.8rem;
  border-radius: 3px;
}
.btn-small:disabled { opacity: 0.5; cursor: not-allowed; }

.btn-primary {
  padding: 0.4rem 0.8rem;
  background: #0f3460;
  border: 1px solid #4fc3f7;
  color: #4fc3f7;
  cursor: pointer;
  border-radius: 3px;
}
.btn-primary:disabled { opacity: 0.5; cursor: not-allowed; }

.btn-secondary {
  padding: 0.3rem 0.7rem;
  background: transparent;
  border: 1px solid #555;
  color: #aaa;
  cursor: pointer;
  font-size: 0.85rem;
  border-radius: 3px;
}
.btn-secondary:hover { border-color: #4fc3f7; color: #4fc3f7; }

.error-banner {
  padding: 0.5rem 1rem;
  background: #7b1a1a;
  color: #ff8a80;
  font-size: 0.85rem;
}
</style>
