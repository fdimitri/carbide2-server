import axios from 'axios'

const API = import.meta.env.VITE_API_URL || 'http://localhost:3000'

function authHeaders() {
  const token = localStorage.getItem('auth_token')
  return token ? { Authorization: `Bearer ${token}` } : {}
}

export async function listProjects() {
  const res = await axios.get(`${API}/api/projects`, { headers: authHeaders() })
  return res.data
}

export async function createProject(name, description = '') {
  const res = await axios.post(`${API}/api/projects`,
    { project: { name, description } },
    { headers: authHeaders() }
  )
  return res.data
}

export async function getWsToken(projectId) {
  const res = await axios.post(`${API}/api/projects/${projectId}/ws_token`, {}, { headers: authHeaders() })
  return res.data.token
}

export async function listChatChannels(projectId) {
  const res = await axios.get(`${API}/api/projects/${projectId}/chat_channels`, { headers: authHeaders() })
  return res.data || []
}

export async function createChatChannel(projectId, name) {
  const res = await axios.post(
    `${API}/api/projects/${projectId}/chat_channels`,
    { chat_channel: { name } },
    { headers: authHeaders() }
  )
  return res.data
}

export async function listChatMessages(projectId, channelId) {
  const res = await axios.get(
    `${API}/api/projects/${projectId}/chat_channels/${channelId}/chat_messages`,
    { headers: authHeaders() }
  )
  return res.data || []
}

export async function createChatMessage(projectId, channelId, text) {
  const res = await axios.post(
    `${API}/api/projects/${projectId}/chat_channels/${channelId}/chat_messages`,
    { chat_message: { text } },
    { headers: authHeaders() }
  )
  return res.data
}
