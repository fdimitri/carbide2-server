import axios from 'axios'

// Auto-detect API URL based on host (supports localhost and WSL bridged networks)
const getApiUrl = () => {
  const host = window.location.hostname
  const port = '3000'
  return `http://${host}:${port}/api`
}

const API_URL = getApiUrl()

const api = axios.create({
  baseURL: API_URL,
  withCredentials: true,
})

const authService = {
  api,
  currentUser: null,
  token: localStorage.getItem('auth_token'),

  get isAuthenticated() {
    return !!this.token && !!this.currentUser
  },

  async login(email, password) {
    try {
      const response = await api.post('/login', {
        user: { email, password },
      })

      const { user, token } = response.data
      this.currentUser = user
      this.token = token
      localStorage.setItem('auth_token', token)
      api.defaults.headers.common['Authorization'] = `Bearer ${token}`

      return { user, token }
    } catch (error) {
      throw new Error(error.response?.data?.message || 'Login failed')
    }
  },

  logout() {
    this.currentUser = null
    this.token = null
    localStorage.removeItem('auth_token')
    delete api.defaults.headers.common['Authorization']
  },

  async checkAuth() {
    const token = localStorage.getItem('auth_token')
    if (token) {
      this.token = token
      api.defaults.headers.common['Authorization'] = `Bearer ${token}`
      // Optionally verify token with backend
      try {
        // const response = await api.get('/users/current')
        // this.currentUser = response.data.user
        return true
      } catch {
        this.logout()
        return false
      }
    }
    return false
  },
}

// Restore token on page load
authService.checkAuth()

export default authService
