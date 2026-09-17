# Rake tasks for the DBFS v2 project filesystem.
#
# Usage:
#   bundle exec rails fs:load[1,/path/to/dir]      # import a directory into project 1
#   bundle exec rails fs:clear[1]                   # tombstone every node in project 1

namespace :fs do
  desc "Load a directory into the DB filesystem. Args: project_id, path"
  task :load, [:project_id, :path] => :environment do |_, args|
    project_id = Integer(args[:project_id] || ENV['PROJECT_ID'])
    path       = args[:path] || ENV['FS_PATH'] || Dir.pwd

    project = Project.find(project_id)
    puts "Loading '#{path}' into project #{project.id} (#{project.name})"

    FsLoader.new(project_id: project_id, root_path: path).load!
  end

  desc "Tombstone every filesystem node in a project (history is kept). Args: project_id"
  task :clear, [:project_id] => :environment do |_, args|
    project_id = Integer(args[:project_id] || ENV['PROJECT_ID'])
    project    = Project.find(project_id)
    store      = ProjectFs.store(project_id)

    top = store.list('/')
    top.each { |node| store.delete(node.path) }
    puts "Tombstoned #{top.size} top-level entries (and their subtrees) for project #{project.id} (#{project.name})"
  end
end
