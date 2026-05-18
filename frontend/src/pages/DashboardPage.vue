<template>
  <div class="dashboard">
    <h1>Carbide2 IDE</h1>

    <section class="projects-section">
      <div class="section-header">
        <h2>Projects</h2>
        <button class="btn-primary" @click="showNewProject = true">+ New Project</button>
      </div>

      <div v-if="showNewProject" class="new-project-form">
        <input v-model="newName" placeholder="Project name" class="input" />
        <input v-model="newDesc" placeholder="Description (optional)" class="input" />
        <button class="btn-primary" @click="createProject" :disabled="!newName.trim()">Create</button>
        <button class="btn-secondary" @click="showNewProject = false">Cancel</button>
      </div>

      <div v-if="loading" class="loading">Loading projects...</div>
      <div v-else-if="projects.length === 0" class="empty">No projects yet. Create one to get started.</div>
      <div v-else class="project-list">
        <div v-for="p in projects" :key="p.id" class="project-card" @click="openProject(p.id)">
          <h3>{{ p.name }}</h3>
          <p>{{ p.description || 'No description' }}</p>
          <span class="project-date">{{ formatDate(p.created_at) }}</span>
        </div>
      </div>
      <div v-if="error" class="error">{{ error }}</div>
    </section>
  </div>
</template>

<script setup>
import { ref, onMounted } from 'vue'
import { useRouter } from 'vue-router'
import { listProjects, createProject as apiCreateProject } from '../services/projectService'

const router    = useRouter()
const projects  = ref([])
const loading   = ref(true)
const error     = ref('')

const showNewProject = ref(false)
const newName = ref('')
const newDesc = ref('')

onMounted(async () => {
  await loadProjects()
})

async function loadProjects() {
  loading.value = true
  error.value   = ''
  try {
    projects.value = await listProjects()
  } catch (e) {
    error.value = e.message || 'Failed to load projects'
  } finally {
    loading.value = false
  }
}

async function createProject() {
  try {
    await apiCreateProject(newName.value.trim(), newDesc.value.trim())
    newName.value = ''
    newDesc.value = ''
    showNewProject.value = false
    await loadProjects()
  } catch (e) {
    error.value = e.message || 'Failed to create project'
  }
}

function openProject(id) {
  router.push(`/projects/${id}`)
}

function formatDate(ts) {
  return new Date(ts).toLocaleDateString()
}
</script>

<style scoped>
.dashboard {
  max-width: 900px;
  margin: 2rem auto;
  padding: 0 1rem;
  font-family: sans-serif;
}

h1 { color: #2c3e50; margin-bottom: 1.5rem; }
h2 { color: #2c3e50; }

.section-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  margin-bottom: 1rem;
}

.new-project-form {
  display: flex;
  gap: 0.5rem;
  margin-bottom: 1rem;
  flex-wrap: wrap;
}

.input {
  padding: 0.4rem 0.7rem;
  border: 1px solid #ccc;
  border-radius: 4px;
  font-size: 0.9rem;
  flex: 1;
  min-width: 160px;
}

.project-list {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(220px, 1fr));
  gap: 1rem;
}

.project-card {
  border: 1px solid #ddd;
  border-radius: 6px;
  padding: 1rem;
  cursor: pointer;
  transition: border-color 0.2s, box-shadow 0.2s;
}

.project-card:hover { border-color: #4fc3f7; box-shadow: 0 2px 8px rgba(79,195,247,0.15); }
.project-card h3 { margin: 0 0 0.3rem; color: #2c3e50; }
.project-card p  { margin: 0 0 0.5rem; color: #666; font-size: 0.85rem; }
.project-date    { font-size: 0.75rem; color: #999; }

.loading, .empty { color: #888; padding: 1rem 0; }
.error { color: #e53935; padding: 0.5rem 0; }

.btn-primary {
  padding: 0.4rem 0.9rem;
  background: #1976d2;
  color: white;
  border: none;
  border-radius: 4px;
  cursor: pointer;
  font-size: 0.9rem;
}
.btn-primary:disabled { opacity: 0.5; cursor: not-allowed; }

.btn-secondary:hover { border-color: #ccc; background: #f5f5f5; }
</style>
