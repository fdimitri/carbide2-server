<template>
  <div class="dashboard">
    <h1>Welcome to Carbide2 IDE</h1>
    <div class="dashboard-grid">
      <div class="card">
        <h2>Projects</h2>
        <p>Manage and create projects here.</p>
        <button class="btn-primary">View Projects</button>
      </div>
      <div class="card">
        <h2>Terminals</h2>
        <p>Open terminals for your projects.</p>
        <button class="btn-primary">Open Terminal</button>
      </div>
      <div class="card">
        <h2>Documentation</h2>
        <p>Learn how to use Carbide2.</p>
        <button class="btn-primary">Read Docs</button>
      </div>
      <div class="card">
        <h2>Settings</h2>
        <p>Configure your workspace.</p>
        <button class="btn-primary">Open Settings</button>
      </div>
    </div>

    <section class="api-test">
      <h2>API Test</h2>
      <button @click="testApi" class="btn-secondary">{{ testing ? 'Testing...' : 'Test Rails API' }}</button>
      <div v-if="apiResponse" class="response">
        <pre>{{ JSON.stringify(apiResponse, null, 2) }}</pre>
      </div>
      <div v-if="apiError" class="error">{{ apiError }}</div>
    </section>
  </div>
</template>

<script setup>
import { ref } from 'vue'
import authService from '../services/authService'

const testing = ref(false)
const apiResponse = ref(null)
const apiError = ref('')

const testApi = async () => {
  testing.value = true
  apiError.value = ''
  apiResponse.value = null

  try {
    const response = await authService.api.get('/api/projects')
    apiResponse.value = response.data
  } catch (err) {
    apiError.value = err.message || 'API test failed'
  } finally {
    testing.value = false
  }
}
</script>

<style scoped>
.dashboard {
  max-width: 1200px;
  margin: 0 auto;
}

.dashboard h1 {
  color: #2c3e50;
  margin-bottom: 2rem;
  font-size: 2rem;
}

.dashboard-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
  gap: 1.5rem;
  margin-bottom: 3rem;
}

.card {
  background: white;
  padding: 1.5rem;
  border-radius: 8px;
  box-shadow: 0 2px 8px rgba(0, 0, 0, 0.1);
  transition: transform 0.2s, box-shadow 0.2s;
}

.card:hover {
  transform: translateY(-2px);
  box-shadow: 0 4px 12px rgba(0, 0, 0, 0.15);
}

.card h2 {
  color: #2c3e50;
  margin-bottom: 0.5rem;
  font-size: 1.2rem;
}

.card p {
  color: #666;
  margin-bottom: 1rem;
  font-size: 0.9rem;
}

.btn-primary {
  background: #667eea;
  color: white;
  border: none;
  padding: 0.5rem 1rem;
  border-radius: 4px;
  cursor: pointer;
  font-size: 0.9rem;
  font-weight: 600;
}

.btn-primary:hover {
  background: #5568d3;
}

.api-test {
  background: white;
  padding: 2rem;
  border-radius: 8px;
  box-shadow: 0 2px 8px rgba(0, 0, 0, 0.1);
}

.api-test h2 {
  color: #2c3e50;
  margin-bottom: 1rem;
}

.btn-secondary {
  background: #27ae60;
  color: white;
  border: none;
  padding: 0.75rem 1.5rem;
  border-radius: 4px;
  cursor: pointer;
  font-size: 0.9rem;
  font-weight: 600;
}

.btn-secondary:hover {
  background: #229954;
}

.response {
  margin-top: 1rem;
  background: #f5f5f5;
  padding: 1rem;
  border-radius: 4px;
  border-left: 4px solid #27ae60;
}

.response pre {
  margin: 0;
  overflow-x: auto;
  font-size: 0.85rem;
  color: #2c3e50;
}

.error {
  margin-top: 1rem;
  background: #fadbd8;
  padding: 1rem;
  border-radius: 4px;
  border-left: 4px solid #e74c3c;
  color: #c0392b;
}
</style>
