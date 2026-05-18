<template>
  <div class="workspace">
    <header class="workspace-header">
      <span class="project-name">{{ project?.name || 'Loading...' }}</span>
      <button class="btn-secondary" @click="$router.push('/dashboard')">← Dashboard</button>
    </header>

    <div class="workspace-body">
      <aside class="explorer">
        <div class="explorer-header">
          <span>Explorer</span>
          <select v-model="explorerFilter" class="tree-filter-select">
            <option value="all">All</option>
            <option value="files">Only Files</option>
            <option value="terminals">Only Terminals</option>
            <option value="channels">Only Channels</option>
          </select>
        </div>
        <input v-model="explorerSearch" class="tree-search" placeholder="Filter explorer..." />

        <div class="tree-group" v-if="showFilesGroup">
          <div class="tree-group-header">Files</div>
          <div class="tree-file-list">
            <button
              v-for="row in filteredFileTreeRows"
              :key="row.node.id"
              class="tree-node tree-node-file"
              :class="{
                active: activePane === 'file' && selectedFileId === row.node.id,
                'tree-node-dir': row.node.type === 'dir'
              }"
              @click="handleFileTreeRowClick(row)">
              <span class="tree-node-indent" :style="{ width: `${row.depth * 14}px` }"></span>
              <span class="tree-twistie" v-if="row.node.type === 'dir'">{{ row.isExpanded ? '▾' : '▸' }}</span>
              <span class="tree-twistie" v-else></span>
              <span class="tree-icon">{{ row.node.type === 'dir' ? '[D]' : '[F]' }}</span>
              <span class="tree-label">{{ row.node.name }}</span>
            </button>
          </div>
          <div v-if="filteredFileTreeRows.length === 0" class="tree-empty">No files in filter</div>
        </div>

        <div class="tree-group" v-if="showTerminalsGroup">
          <div class="tree-group-header">Terminals</div>
          <button class="tree-node tree-node-create" @click="openTerminal" :disabled="terminalLoading">
            <span class="tree-icon">[+]</span>{{ terminalLoading ? 'Opening...' : 'New Terminal' }}
          </button>
          <button
            v-for="t in filteredTerminalNodes"
            :key="t.id"
            class="tree-node"
            :class="{ active: activePane === 'terminal' && selectedTerminalId === t.id }"
            @click="selectTerminalNode(t.id)">
            <span class="tree-icon">[T]</span>terminal #{{ t.id }}
          </button>
          <div v-if="filteredTerminalNodes.length === 0" class="tree-empty">No terminals in filter</div>
        </div>

        <div class="tree-group" v-if="showChannelsGroup">
          <div class="tree-group-header">Channels</div>
          <button class="tree-node tree-node-create" @click="createChannel">
            <span class="tree-icon">[+]</span>New Channel
          </button>
          <button
            v-for="c in filteredChannelNodes"
            :key="c.id"
            class="tree-node"
            :class="{ active: activePane === 'chat' && selectedChatChannelId === c.id }"
            @click="selectChannelNode(c.id)">
            <span class="tree-icon">[#]</span>{{ c.name }}
          </button>
          <div v-if="filteredChannelNodes.length === 0" class="tree-empty">No channels in filter</div>
        </div>
      </aside>

      <section class="main-pane">
        <div class="panel-header pane-header">
          <span v-if="activePane === 'terminal'">Terminal</span>
          <span v-else-if="activePane === 'chat'">Channel #{{ activeChannelName }}</span>
          <span v-else>File {{ selectedFileId }}</span>
          <div class="pane-meta" v-if="activePane === 'chat'">{{ chatUsers.length }} online</div>
        </div>

        <div v-if="activePane === 'terminal'" class="pane-content">
          <div ref="terminalEl" class="xterm-container" @click="xterm?.focus()"></div>
          <div v-if="!terminalActive" class="panel-placeholder">Select or create a terminal from the tree.</div>
        </div>

        <div v-else-if="activePane === 'chat'" class="pane-content chat-pane-content">
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
              :placeholder="chatJoining ? 'Joining channel...' : 'Type a message...'"
              :disabled="!wsConnected || chatJoining"
              class="chat-input"
            />
            <button class="btn-primary" @click="sendChat" :disabled="!canSendChat">
              Send
            </button>
          </div>
        </div>

        <div v-else class="pane-content">
          <div class="panel-placeholder">
            File preview pane for <strong>{{ selectedFileId }}</strong>.
            <br />
            Use the tree filter to show only files when you want file-focused navigation.
          </div>
        </div>
      </section>
    </div>

    <div v-if="error" class="error-banner">{{ error }}</div>
  </div>
</template>

<script setup>
import { ref, onMounted, onBeforeUnmount, nextTick, computed, watch } from 'vue'
import { useRoute } from 'vue-router'
import { Terminal } from '@xterm/xterm'
import { FitAddon } from '@xterm/addon-fit'
import '@xterm/xterm/css/xterm.css'
import workerSocket from '../services/workerSocket'
import { listProjects, getWsToken, listChatChannels, createChatChannel, listChatMessages, createChatMessage } from '../services/projectService'
import authService from '../services/authService'

const route        = useRoute()
const projectId    = Number(route.params.id)
const project      = ref(null)
const error        = ref('')
const wsConnected  = ref(false)
const activePane = ref('terminal')
const explorerFilter = ref('all')
const explorerSearch = ref('')
const selectedFileId = ref('README.md')
const fileTree = ref([
  {
    id: 'app',
    name: 'app',
    type: 'dir',
    children: [
      {
        id: 'app/controllers',
        name: 'controllers',
        type: 'dir',
        children: [
          { id: 'app/controllers/application_controller.rb', name: 'application_controller.rb', type: 'file' },
          {
            id: 'app/controllers/api',
            name: 'api',
            type: 'dir',
            children: [
              { id: 'app/controllers/api/chat_channels_controller.rb', name: 'chat_channels_controller.rb', type: 'file' },
              { id: 'app/controllers/api/chat_messages_controller.rb', name: 'chat_messages_controller.rb', type: 'file' }
            ]
          }
        ]
      },
      {
        id: 'app/models',
        name: 'models',
        type: 'dir',
        children: [
          { id: 'app/models/project.rb', name: 'project.rb', type: 'file' },
          { id: 'app/models/chat_channel.rb', name: 'chat_channel.rb', type: 'file' },
          { id: 'app/models/chat_message.rb', name: 'chat_message.rb', type: 'file' }
        ]
      }
    ]
  },
  {
    id: 'frontend',
    name: 'frontend',
    type: 'dir',
    children: [
      {
        id: 'frontend/src',
        name: 'src',
        type: 'dir',
        children: [
          {
            id: 'frontend/src/pages',
            name: 'pages',
            type: 'dir',
            children: [
              { id: 'frontend/src/pages/ProjectPage.vue', name: 'ProjectPage.vue', type: 'file' }
            ]
          },
          {
            id: 'frontend/src/services',
            name: 'services',
            type: 'dir',
            children: [
              { id: 'frontend/src/services/workerSocket.js', name: 'workerSocket.js', type: 'file' },
              { id: 'frontend/src/services/projectService.js', name: 'projectService.js', type: 'file' }
            ]
          }
        ]
      }
    ]
  },
  {
    id: 'worker',
    name: 'worker',
    type: 'dir',
    children: [
      { id: 'worker/worker.rb', name: 'worker.rb', type: 'file' },
      { id: 'worker/terminal_instance.rb', name: 'terminal_instance.rb', type: 'file' },
      { id: 'worker/chat_room.rb', name: 'chat_room.rb', type: 'file' },
      { id: 'worker/session.rb', name: 'session.rb', type: 'file' }
    ]
  },
  { id: 'README.md', name: 'README.md', type: 'file' },
  { id: 'UX_NOTES.md', name: 'UX_NOTES.md', type: 'file' }
])
const expandedDirs = ref(new Set(['app', 'app/controllers', 'frontend', 'frontend/src', 'worker']))

// Terminal
const terminalEl       = ref(null)
const terminalActive   = ref(false)
const terminalLoading  = ref(false)
const terminalList     = ref([])
const selectedTerminalId = ref(null)
let createTerminalTimeout = null
let xterm    = null
let fitAddon = null
let terminalId = null
const offHandlers = []

// Chat
const chatEl       = ref(null)
const chatChannels = ref([])
const selectedChatChannelId = ref(null)
const chatMessages = ref([])
const chatUsers    = ref([])
const chatInput    = ref('')
const chatJoining  = ref(false)
const joinedChatChannels = ref(new Set())
let joinTimeoutHandle = null
const currentUserId = computed(() => authService.userId())
const activeChannelName = computed(() => {
  const ch = chatChannels.value.find(c => c.id === Number(selectedChatChannelId.value))
  return ch?.name || 'general'
})

const showFilesGroup = computed(() => explorerFilter.value === 'all' || explorerFilter.value === 'files')
const showTerminalsGroup = computed(() => explorerFilter.value === 'all' || explorerFilter.value === 'terminals')
const showChannelsGroup = computed(() => explorerFilter.value === 'all' || explorerFilter.value === 'channels')

const filteredFileTreeRows = computed(() => {
  const query = explorerSearch.value.trim().toLowerCase()

  const subtreeMatches = (node) => {
    const direct = node.name.toLowerCase().includes(query)
    if (direct) return true
    if (node.type !== 'dir' || !node.children?.length) return false
    return node.children.some(subtreeMatches)
  }

  const rows = []
  const visit = (nodes, depth) => {
    nodes.forEach((node) => {
      if (query && !subtreeMatches(node)) return
      const isExpanded = node.type === 'dir' && (query ? true : expandedDirs.value.has(node.id))
      rows.push({ node, depth, isExpanded })
      if (node.type === 'dir' && isExpanded && node.children?.length) {
        visit(node.children, depth + 1)
      }
    })
  }

  visit(fileTree.value, 0)
  return rows
})

const filteredTerminalNodes = computed(() => {
  const query = explorerSearch.value.trim().toLowerCase()
  if (!query) return terminalList.value
  return terminalList.value.filter(t => String(t.id).includes(query) || String(t.status || '').toLowerCase().includes(query))
})

const filteredChannelNodes = computed(() => {
  const query = explorerSearch.value.trim().toLowerCase()
  if (!query) return chatChannels.value
  return chatChannels.value.filter(c => c.name.toLowerCase().includes(query))
})

const canSendChat = computed(() => {
  const cid = Number(selectedChatChannelId.value)
  return wsConnected.value && !chatJoining.value && !!chatInput.value.trim() && joinedChatChannels.value.has(cid)
})

function activeChannelMatches(payload) {
  const active = Number(selectedChatChannelId.value)
  const incoming = Number(payload?.channel_id ?? payload?.chat_channel_id)
  return !!active && !!incoming && active === incoming
}

function isJoinedChannel(channelId) {
  return joinedChatChannels.value.has(Number(channelId))
}

function toggleDirectory(path) {
  if (expandedDirs.value.has(path)) {
    expandedDirs.value.delete(path)
  } else {
    expandedDirs.value.add(path)
  }
  expandedDirs.value = new Set(expandedDirs.value)
}

function handleFileTreeRowClick(row) {
  if (row.node.type === 'dir') {
    toggleDirectory(row.node.id)
    return
  }
  selectFileNode(row.node.id)
}

function startJoinWait(channelId) {
  chatJoining.value = true
  if (joinTimeoutHandle) clearTimeout(joinTimeoutHandle)
  joinTimeoutHandle = setTimeout(() => {
    if (!isJoinedChannel(channelId) && Number(selectedChatChannelId.value) === Number(channelId)) {
      chatJoining.value = false
      error.value = 'Could not join channel yet. Check worker connection and try again.'
    }
    joinTimeoutHandle = null
  }, 4500)
}

function clearJoinWaitIfActive(channelId) {
  if (Number(selectedChatChannelId.value) !== Number(channelId)) return
  chatJoining.value = false
  if (joinTimeoutHandle) {
    clearTimeout(joinTimeoutHandle)
    joinTimeoutHandle = null
  }
}

onMounted(async () => {
  try {
    const projects = await listProjects()
    project.value  = projects.find(p => p.id === projectId)

    // Load channels + default room history before websocket messages.
    chatChannels.value = await listChatChannels(projectId)
    if (chatChannels.value.length === 0) {
      const general = await createChatChannel(projectId, 'general')
      chatChannels.value = [general]
    }
    selectedChatChannelId.value = chatChannels.value[0].id
    chatMessages.value = await listChatMessages(projectId, selectedChatChannelId.value)

    // Fetch token now, but connect only after handlers are registered to avoid
    // missing early 'system:connected' and chat join events.
    const token = await getWsToken(projectId)

    offHandlers.push(
      workerSocket.on('system', 'connected', () => {
        wsConnected.value = true
        joinedChatChannels.value = new Set()
        if (selectedChatChannelId.value) {
          startJoinWait(selectedChatChannelId.value)
          workerSocket.send('chat', 'join', { channel_id: selectedChatChannelId.value })
        }
      })
    )

    // Terminal list handler
    offHandlers.push(
      workerSocket.on('term', 'list', (p) => {
        terminalList.value = p.terminals || []
      }),
      workerSocket.on('term', 'created', (p) => {
        // Terminal was created, list will be broadcasted
        if (createTerminalTimeout) {
          clearTimeout(createTerminalTimeout)
          createTerminalTimeout = null
        }
        const createdTerminalId = p.terminal_id
        selectedTerminalId.value = createdTerminalId
        connectToTerminal(createdTerminalId)
      })
    )

    offHandlers.push(
      workerSocket.on('system', 'error', (p) => {
        if (createTerminalTimeout) {
          clearTimeout(createTerminalTimeout)
          createTerminalTimeout = null
        }
        terminalLoading.value = false
        error.value = p?.message || 'Worker error'
      })
    )

    // Chat handlers
    offHandlers.push(
      workerSocket.on('chat', 'message', (p) => {
        if (!activeChannelMatches(p)) return
        chatMessages.value.push(p)
        nextTick(() => scrollChat())
      }),
      workerSocket.on('chat', 'user_join', (p) => {
        if (!activeChannelMatches(p)) return
        if (!chatUsers.value.find(u => u.user_id === p.user_id)) {
          chatUsers.value.push({ user_id: p.user_id, name: p.name })
        }
        chatMessages.value.push({ system: true, text: `${p.name} joined`, timestamp: new Date().toISOString() })
        nextTick(() => scrollChat())
      }),
      workerSocket.on('chat', 'user_leave', (p) => {
        if (!activeChannelMatches(p)) return
        chatUsers.value = chatUsers.value.filter(u => u.user_id !== p.user_id)
        chatMessages.value.push({ system: true, text: `${p.name} left`, timestamp: new Date().toISOString() })
      }),
      workerSocket.on('chat', 'user_list', (p) => {
        if (!activeChannelMatches(p)) return
        chatUsers.value = p.users || []
      }),
      workerSocket.on('chat', 'joined', (p) => {
        const cid = Number(p.channel_id)
        if (cid) joinedChatChannels.value.add(cid)
        if (cid) {
          clearJoinWaitIfActive(cid)
          error.value = ''
        }
      }),
      workerSocket.on('chat', 'left', (p) => {
        const cid = Number(p.channel_id)
        if (cid) joinedChatChannels.value.delete(cid)
        if (cid && cid === Number(selectedChatChannelId.value)) {
          chatJoining.value = true
        }
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

    // Connect after registering all handlers so no initial events are missed.
    workerSocket.connect(token)
  } catch (e) {
    error.value = e.message || 'Failed to connect'
  }
})

// Re-focus xterm whenever terminal becomes active (handles re-renders)
watch(terminalActive, (active) => {
  if (active) nextTick(() => xterm?.focus())
})

// Route keystrokes to xterm when it's active and nothing else has focus
function onDocumentKeydown(e) {
  if (!terminalActive.value || !xterm) return
  const tag = document.activeElement?.tagName
  if (tag === 'INPUT' || tag === 'TEXTAREA') return
  xterm.focus()
}

onMounted(() => { document.addEventListener('keydown', onDocumentKeydown) })

onBeforeUnmount(() => {
  document.removeEventListener('keydown', onDocumentKeydown)
  if (joinTimeoutHandle) {
    clearTimeout(joinTimeoutHandle)
    joinTimeoutHandle = null
  }
  offHandlers.forEach(off => off())
  workerSocket.disconnect()
  xterm?.dispose()
})

async function openTerminal() {
  if (terminalLoading.value) return
  terminalLoading.value = true
  error.value = ''
  try {
    // Send create message via WebSocket
    workerSocket.send('term', 'create', {})
    // Never leave UI stuck if worker does not answer.
    createTerminalTimeout = setTimeout(() => {
      terminalLoading.value = false
      error.value = 'Timed out creating terminal. Check worker logs and JWT secret.'
      createTerminalTimeout = null
    }, 5000)
  } catch (e) {
    if (createTerminalTimeout) {
      clearTimeout(createTerminalTimeout)
      createTerminalTimeout = null
    }
    error.value = e.message || 'Failed to create terminal'
    terminalLoading.value = false
  }
}

async function connectToTerminal(tid) {
  terminalLoading.value = true
  try {
    terminalId = tid
    await nextTick()

    if (!xterm) {
      xterm    = new Terminal({ cursorBlink: true, fontSize: 14, theme: { background: '#1e1e1e' } })
      fitAddon = new FitAddon()
      xterm.loadAddon(fitAddon)
      xterm.open(terminalEl.value)
      fitAddon.fit()

      xterm.onData(data => {
        console.log('[xterm onData] data:', JSON.stringify(data), 'terminalId:', terminalId, 'wsReady:', workerSocket._ready)
        workerSocket.send('term', 'input', { terminal_id: terminalId, data })
      })

      xterm.onResize(({ cols, rows }) => {
        workerSocket.send('term', 'resize', { terminal_id: terminalId, cols, rows })
      })

      window.addEventListener('resize', () => fitAddon?.fit())
    } else {
      // Clear terminal when switching to new session
      xterm.reset()
    }

    workerSocket.send('term', 'join', { terminal_id: terminalId })
    activePane.value = 'terminal'
    terminalActive.value = true
    // Focus AFTER Vue re-renders (terminalActive flip may cause DOM changes)
    await nextTick()
    xterm.focus()
  } catch (e) {
    error.value = e.message || 'Failed to connect to terminal'
  } finally {
    terminalLoading.value = false
  }
}

async function refreshTerminalList() {
  try {
    // Terminal list is broadcasted by worker, no need to manually refresh
  } catch (e) {
    console.error('Failed to refresh terminal list:', e)
  }
}

async function switchTerminal() {
  if (!selectedTerminalId.value) return
  await connectToTerminal(selectedTerminalId.value)
}

async function selectTerminalNode(tid) {
  selectedTerminalId.value = tid
  await switchTerminal()
}

async function switchChatChannel() {
  if (!selectedChatChannelId.value) return
  const nextChannel = Number(selectedChatChannelId.value)
  activePane.value = 'chat'
  startJoinWait(nextChannel)

  // Join selected channel immediately so loading history can never block chat state.
  workerSocket.send('chat', 'join', { channel_id: nextChannel })

  // PART previous active channel if joined, then JOIN the next channel.
  joinedChatChannels.value.forEach((cid) => {
    if (cid !== nextChannel) {
      workerSocket.send('chat', 'leave', { channel_id: cid })
    }
  })

  chatUsers.value = []
  try {
    chatMessages.value = await listChatMessages(projectId, nextChannel)
  } catch (e) {
    chatMessages.value = []
    error.value = e.message || 'Failed to load channel history'
  }
}

async function selectChannelNode(channelId) {
  selectedChatChannelId.value = channelId
  await switchChatChannel()
}

function selectFileNode(fileId) {
  selectedFileId.value = fileId
  activePane.value = 'file'
}

async function createChannel() {
  const name = window.prompt('Channel name (e.g. build, backend, incidents):')
  if (!name || !name.trim()) return
  const channel = await createChatChannel(projectId, name.trim())
  chatChannels.value.push(channel)
  selectedChatChannelId.value = channel.id
  await switchChatChannel()
}


async function sendChat() {
  const text = chatInput.value.trim()
  if (!text || !selectedChatChannelId.value) return

  if (!isJoinedChannel(selectedChatChannelId.value)) {
    chatJoining.value = true
    error.value = 'Joining selected channel...'
    return
  }

  error.value = ''

  try {
    await createChatMessage(projectId, selectedChatChannelId.value, text)
  } catch (e) {
    error.value = e.message || 'Failed to save chat message'
    return
  }

  workerSocket.send('chat', 'message', { channel_id: selectedChatChannelId.value, text })
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
  --bg-0: #0d1219;
  --bg-1: #111a26;
  --bg-2: #162233;
  --bg-3: #1f2f45;
  --line: #2b3d58;
  --text: #dce6f7;
  --muted: #91a2bc;
  --accent: #2ec4b6;
  --warn: #f07167;
  display: flex;
  flex-direction: column;
  height: 100vh;
  color: var(--text);
  background:
    radial-gradient(circle at 0% 0%, rgba(46, 196, 182, 0.08) 0, transparent 30%),
    radial-gradient(circle at 100% 100%, rgba(85, 130, 255, 0.1) 0, transparent 35%),
    var(--bg-0);
  font-family: "IBM Plex Sans", "Manrope", "Segoe UI", sans-serif;
}

.workspace-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 0.65rem 1rem;
  background: linear-gradient(90deg, var(--bg-2), #132135);
  border-bottom: 1px solid var(--line);
}

.project-name {
  font-size: 1.05rem;
  font-weight: 700;
  letter-spacing: 0.01em;
}

.workspace-body {
  display: grid;
  grid-template-columns: 300px minmax(0, 1fr);
  flex: 1;
  min-height: 0;
}

.explorer {
  border-right: 1px solid var(--line);
  background: linear-gradient(180deg, rgba(23, 34, 51, 0.95), rgba(16, 25, 39, 0.95));
  display: flex;
  flex-direction: column;
  min-height: 0;
}

.explorer-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 0.65rem 0.75rem;
  border-bottom: 1px solid var(--line);
  font-size: 0.84rem;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.08em;
}

.tree-filter-select,
.tree-search,
.chat-input {
  background: #0f1724;
  border: 1px solid var(--line);
  color: var(--text);
  border-radius: 0.35rem;
}

.tree-filter-select {
  font-size: 0.75rem;
  padding: 0.2rem 0.35rem;
}

.tree-search {
  margin: 0.6rem 0.6rem 0.4rem;
  padding: 0.45rem 0.55rem;
  font-size: 0.82rem;
}

.tree-group {
  margin: 0.25rem 0.4rem;
  border: 1px solid rgba(84, 110, 146, 0.3);
  border-radius: 0.45rem;
  overflow: hidden;
}

.tree-file-list {
  max-height: 280px;
  overflow-y: auto;
}

.tree-group-header {
  background: var(--bg-2);
  color: var(--muted);
  padding: 0.42rem 0.55rem;
  font-size: 0.72rem;
  font-weight: 700;
  letter-spacing: 0.08em;
  text-transform: uppercase;
}

.tree-node {
  width: 100%;
  text-align: left;
  background: transparent;
  border: 0;
  border-top: 1px solid rgba(84, 110, 146, 0.2);
  color: var(--text);
  padding: 0.42rem 0.55rem;
  font-size: 0.84rem;
  cursor: pointer;
  display: flex;
  align-items: center;
  gap: 0.45rem;
}

.tree-node:hover { background: rgba(74, 110, 157, 0.35); }

.tree-node-file {
  gap: 0.3rem;
  padding-right: 0.35rem;
}

.tree-node-dir {
  color: #d1dcf2;
}

.tree-node-indent {
  flex: 0 0 auto;
}

.tree-twistie {
  width: 0.8rem;
  flex: 0 0 0.8rem;
  color: #a4b6d0;
  font-size: 0.72rem;
  text-align: center;
}

.tree-label {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.tree-node.active {
  background: rgba(46, 196, 182, 0.17);
  color: #d7fff6;
  box-shadow: inset 2px 0 0 var(--accent);
}

.tree-node:disabled {
  opacity: 0.6;
  cursor: not-allowed;
}

.tree-node-create {
  color: #c5ffe2;
  font-weight: 600;
}

.tree-icon {
  color: #7ce9de;
  font-family: "IBM Plex Mono", "Fira Code", monospace;
  font-size: 0.74rem;
}

.tree-empty {
  padding: 0.55rem;
  color: var(--muted);
  font-size: 0.78rem;
}

.main-pane {
  display: flex;
  flex-direction: column;
  min-width: 0;
  min-height: 0;
}

.panel-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  background: var(--bg-1);
  border-bottom: 1px solid var(--line);
  padding: 0.5rem 0.85rem;
  font-weight: 700;
}

.pane-meta {
  font-size: 0.75rem;
  color: #8ef7be;
  font-weight: 600;
}

.pane-content {
  display: flex;
  flex-direction: column;
  flex: 1;
  min-height: 0;
}

.xterm-container {
  flex: 1;
  min-height: 0;
  padding: 0.35rem;
  background: #0b1017;
}

.panel-placeholder {
  flex: 1;
  display: grid;
  place-items: center;
  text-align: center;
  color: var(--muted);
  padding: 1rem;
}

.chat-pane-content {
  background: linear-gradient(180deg, #0f1826, #0c1420);
}

.chat-messages {
  flex: 1;
  overflow-y: auto;
  padding: 0.75rem;
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
}

.chat-msg {
  display: flex;
  flex-direction: column;
  gap: 0.1rem;
  max-width: 80ch;
}

.chat-msg--own .chat-name { color: #8df4e9; }

.chat-name {
  color: #b4c5df;
  font-size: 0.8rem;
  font-weight: 600;
}

.chat-text {
  color: #eff5ff;
  font-size: 0.86rem;
  line-height: 1.3;
  word-break: break-word;
}

.chat-time {
  color: #778ba8;
  font-size: 0.72rem;
}

.chat-input-row {
  display: flex;
  gap: 0.5rem;
  padding: 0.55rem;
  border-top: 1px solid var(--line);
  background: rgba(17, 26, 38, 0.85);
}

.chat-input {
  flex: 1;
  padding: 0.45rem 0.65rem;
  font-size: 0.85rem;
}

.chat-input:focus,
.tree-search:focus,
.tree-filter-select:focus {
  outline: none;
  border-color: #67e8dc;
}

.btn-primary,
.btn-secondary {
  border-radius: 0.35rem;
  cursor: pointer;
}

.btn-primary {
  padding: 0.42rem 0.85rem;
  background: #123549;
  border: 1px solid #2ec4b6;
  color: #9efdf3;
}

.btn-primary:disabled {
  opacity: 0.55;
  cursor: not-allowed;
}

.btn-secondary {
  padding: 0.34rem 0.7rem;
  background: transparent;
  border: 1px solid #587296;
  color: #c5d4ea;
  font-size: 0.85rem;
}

.btn-secondary:hover {
  border-color: #7ce9de;
  color: #dffffa;
}

.error-banner {
  padding: 0.5rem 0.8rem;
  background: #4d1b27;
  color: #ffb9c8;
  border-top: 1px solid #7f3243;
  font-size: 0.84rem;
}

@media (max-width: 980px) {
  .workspace-body {
    grid-template-columns: 1fr;
    grid-template-rows: 42vh minmax(0, 1fr);
  }

  .explorer {
    border-right: none;
    border-bottom: 1px solid var(--line);
  }
}
</style>
