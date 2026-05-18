<template>
  <div class="app">
    <nav class="navbar">
      <div class="nav-brand">Carbide2 IDE</div>
      <div class="nav-menu" v-if="authService.isAuthenticated">
        <span class="nav-user">{{ authService.currentUser?.email }}</span>
        <button class="btn-logout" @click="logout">Logout</button>
      </div>
    </nav>
    <main class="main" :class="{ 'main--workspace': $route.path.startsWith('/projects/') }">
      <router-view />
    </main>
  </div>
</template>

<script>
import { ref, onMounted } from 'vue'
import authService from './services/authService'

export default {
  setup() {
    const router = useRouter()

    const logout = () => {
      authService.logout()
      router.push('/login')
    }

    return {
      authService,
      logout,
    }
  },
}
</script>

<script setup>
import { useRouter } from 'vue-router'
</script>

<style scoped>
.app {
  display: flex;
  flex-direction: column;
  min-height: 100vh;
  background: #f5f5f5;
}

.navbar {
  display: flex;
  justify-content: space-between;
  align-items: center;
  background: #2c3e50;
  color: white;
  padding: 1rem 2rem;
  box-shadow: 0 2px 4px rgba(0, 0, 0, 0.1);
}

.nav-brand {
  font-size: 1.5rem;
  font-weight: bold;
}

.nav-menu {
  display: flex;
  gap: 1rem;
  align-items: center;
}

.nav-user {
  font-size: 0.9rem;
  opacity: 0.8;
}

.btn-logout {
  background: #e74c3c;
  color: white;
  border: none;
  padding: 0.5rem 1rem;
  border-radius: 4px;
  cursor: pointer;
  font-size: 0.9rem;
}

.btn-logout:hover {
  background: #c0392b;
}

.main {
  flex: 1;
  padding: 2rem;
}

.main--workspace {
  padding: 0;
  min-height: 0;
  overflow: hidden;
}
</style>
