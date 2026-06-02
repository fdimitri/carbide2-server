# app/jobs/import_from_git_job.rb
#
# Clones a public git repo into a project's on-disk root. Runs `git clone
# --depth 1` in a forked subprocess so a hung clone doesn't block the Rails
# worker. The on-disk VfsWatcher (started by the EventMachine worker for
# every project) picks up the new files automatically into the VFS via
# inotify, so we don't need to walk the tree here.
#
# Idempotent guard: refuses to clone if the project already has any
# DirectoryEntry rows. Controller enforces this too; double-checked here in
# case of a race between two import requests.

require 'open3'

class ImportFromGitJob < ApplicationJob
  queue_as :default

  TIMEOUT_SECONDS = Integer(ENV.fetch('IMPORT_FROM_GIT_TIMEOUT_S', '1800')) # 30 min default

  def perform(project_id, git_url, git_ref = 'main')
    project = Project.find(project_id)
    setting = project.project_setting || project.ensure_project_setting!
    root    = setting.root_path

    if DirectoryEntry.where(project_id: project.id).exists?
      Rails.logger.warn("[ImportFromGitJob] project #{project.id} not empty, refusing import")
      return
    end

    unless git_url.is_a?(String) && git_url.match?(/\A(https?:\/\/|git@)[^\s]+\z/)
      Rails.logger.error("[ImportFromGitJob] rejecting suspect URL: #{git_url.inspect}")
      return
    end

    FileUtils.mkdir_p(root)
    unless Dir.empty?(root)
      Rails.logger.warn("[ImportFromGitJob] root #{root} non-empty, refusing import")
      return
    end

    Rails.logger.info("[ImportFromGitJob] project=#{project.id} cloning #{git_url}@#{git_ref} -> #{root}")

    cmd = ['git', 'clone', '--depth', '1', '--branch', git_ref.to_s, '--', git_url, root]
    out, status = run_with_timeout(cmd, TIMEOUT_SECONDS)
    if status&.success?
      Rails.logger.info("[ImportFromGitJob] clone OK for project=#{project.id}")
    else
      Rails.logger.error("[ImportFromGitJob] clone FAILED for project=#{project.id}: #{out}")
      # Wipe partial clone so the user can retry.
      FileUtils.rm_rf(Dir.glob(File.join(root, '*')) + Dir.glob(File.join(root, '.[!.]*')))
    end
  end

  private

  def run_with_timeout(cmd, timeout)
    out_buf = +''
    stdin, stdout_err, wait_thr = Open3.popen2e(*cmd)
    stdin.close

    reader = Thread.new do
      stdout_err.each_line { |line| out_buf << line }
    end

    start = Time.now
    while wait_thr.alive?
      if Time.now - start > timeout
        Process.kill('TERM', wait_thr.pid) rescue nil
        sleep 2
        Process.kill('KILL', wait_thr.pid) rescue nil
        out_buf << "\n[ImportFromGitJob] timeout after #{timeout}s\n"
        break
      end
      sleep 1
    end
    reader.join(5)
    [out_buf, wait_thr.value]
  ensure
    stdout_err&.close
  end
end
