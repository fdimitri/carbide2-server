# Seeded dev user (Devise-compatible)
dev_user = User.find_or_create_by!(email: 'dev@example.com') do |u|
  u.password = 'password'
  u.password_confirmation = 'password'
end
admin_user = User.find_or_create_by!(email: 'admin@example.com') do |u|
  u.password = 'password'
  u.password_confirmation = 'password'
end

# Ensure dev user has a preferences row (after_create handles new signups)
dev_user.create_user_preference! unless dev_user.user_preference

# Default project — create then grant dev_user access via membership
project = Project.find_or_create_by!(name: 'Demo Project') do |p|
  p.description = 'Default project for dev'
end
# Backfill for projects created before the after_create hook existed.
project.ensure_project_setting!
ProjectMembership.find_or_create_by!(user: dev_user, project: project)
ProjectMembership.find_or_create_by!(user: admin_user, project: project)

# Seed a small in-VFS file tree so the IDE has something to open on a fresh
# cluster. Idempotent: each create_file! is wrapped so reruns are no-ops if the
# srcpath already exists. The VFS is independent of any on-disk path.
seed_files = {
  '/README.md'        => "# Demo Project\n\nThis is a seeded project for local dev.\n",
  '/src/main.rb'      => "puts 'hello from the demo project'\n",
  '/src/lib/util.rb'  => <<~'RUBY',
    module Util
      def self.greet(name) = "hi, #{name}"
    end
  RUBY
  '/docs/notes.txt'   => "scratch notes\n",
}
seed_files.each do |path, body|
  next if DirectoryEntry.exists?(project_id: project.id, srcpath: path)
  DirectoryEntry.create_file!(
    project_id: project.id,
    srcpath: path,
    user_id: dev_user.id,
    data: body,
    mkdirp: true
  )
end

# -------------------------------------------------------------------------
# Agents — seed a couple of starter LLM personas pointed at an OpenAI-
# compatible endpoint. The default URL targets LM Studio's local server
# convention (host machine on port 1234). Override via env:
#
#   AGENT_DEFAULT_URL    — base URL (default http://host.docker.internal:1234/v1)
#   AGENT_DEFAULT_MODEL  — model name (default qwen2.5-coder-14b-instruct)
#
# Inside k3d the workspace pod can reach the host via the LAN IP of the
# host machine; set AGENT_DEFAULT_URL to that explicitly per cluster.
# Seeds are idempotent (find_or_create_by! on slug).
# -------------------------------------------------------------------------
default_agent_url   = ENV.fetch('AGENT_DEFAULT_URL',   'http://host.docker.internal:1234/v1')
default_agent_model = ENV.fetch('AGENT_DEFAULT_MODEL', 'qwen3-coder-30b-a3b-instruct')

Agent.find_or_create_by!(slug: 'coder') do |a|
  a.name          = 'Coder'
  a.description   = 'General-purpose coding assistant with read-only project access plus shell_exec in user-marked terminals.'
  a.role          = 'coder'
  a.provider_url  = default_agent_url
  a.model         = default_agent_model
  a.system_prompt = <<~PROMPT.strip
    You are Carbide, an AI pair-programmer embedded in a collaborative
    cloud IDE. The user is working in a specific project. Use the
    read_file and list_dir tools to look at code BEFORE answering
    questions about it; do not guess. Keep replies short and concrete.

    You may also run shell commands via shell_exec, but ONLY in terminals
    the user has explicitly marked agent-accessible. Call list_terminals
    first to find available terminal_ids. The user watches the command
    stream live. Prefer non-destructive, read-only commands; explain
    before running anything that writes.
  PROMPT
  a.allowed_tools       = %w[read_file list_dir list_terminals shell_exec]
  a.shell_exec_enabled  = true
  a.sampling            = { 'temperature' => 0.2, 'max_tokens' => 2048 }
  a.enabled             = true
end

Agent.find_or_create_by!(slug: 'reviewer') do |a|
  a.name          = 'Reviewer'
  a.description   = 'Reviews code for bugs and clarity. Read-only.'
  a.role          = 'reviewer'
  a.provider_url  = default_agent_url
  a.model         = default_agent_model
  a.system_prompt = <<~PROMPT.strip
    You are a careful code reviewer. Use read_file and list_dir to
    examine the code under discussion. Point out concrete issues with
    file/line references. Do not propose changes you have not read the
    surrounding context for. Be blunt; the user prefers it.
  PROMPT
  a.allowed_tools = %w[read_file list_dir]
  a.sampling      = { 'temperature' => 0.1, 'max_tokens' => 2048 }
  a.enabled       = true
end

Agent.find_or_create_by!(slug: 'safety') do |a|
  a.name          = 'Safety guard'
  a.description   = 'Chat-only sanity check; cannot read project files.'
  a.role          = 'safety'
  a.provider_url  = default_agent_url
  a.model         = default_agent_model
  a.system_prompt = <<~PROMPT.strip
    You evaluate proposed actions for risk. You have no tools. Reply
    with a short risk assessment and a recommendation.
  PROMPT
  a.allowed_tools = []
  a.sampling      = { 'temperature' => 0.0, 'max_tokens' => 512 }
  a.enabled       = true
end

