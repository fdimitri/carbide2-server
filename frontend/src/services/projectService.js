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
