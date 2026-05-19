# REST API for the database-backed virtual filesystem.
# All routes are scoped under /api/projects/:project_id/fs/...
#
# GET    /api/projects/:project_id/fs/tree          — full file tree JSON
# GET    /api/projects/:project_id/fs/content       — file content (calc_current)
#          ?path=/src/app.rb
# POST   /api/projects/:project_id/fs/files         — create file
#          { path:, content: (optional) }
# POST   /api/projects/:project_id/fs/dirs          — create directory
#          { path: }
# PATCH  /api/projects/:project_id/fs/rename        — rename entry
#          { path:, new_name: }
# DELETE /api/projects/:project_id/fs/entry         — delete entry
#          { path: }
class Api::DirectoryEntriesController < Api::BaseController
  before_action :load_project

  def tree
    render json: DirectoryEntry.tree_for_project(@project.id)
  end

  def content
    entry = find_entry!(params[:path])
    return unless entry
    return render json: { error: 'entry is a directory' }, status: :unprocessable_entity if entry.ftype == 'folder'
    render json: { path: entry.srcpath, content: entry.calc_current }
  end

  def create_file
    path    = require_param!(:path)
    return unless path
    content = params[:content].to_s
    entry   = DirectoryEntry.create_file!(
      project_id: @project.id,
      srcpath:    path,
      user_id:    @current_user_id,
      data:       content,
      mkdirp:     params[:mkdirp] == true || params[:mkdirp] == 'true'
    )
    render json: entry_json(entry), status: :created
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  rescue ArgumentError, RuntimeError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def create_dir
    path  = require_param!(:path)
    return unless path
    entry = DirectoryEntry.mkdir_p!(project_id: @project.id, srcpath: path, user_id: @current_user_id)
    render json: entry_json(entry), status: :created
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def rename
    path     = require_param!(:path)
    return unless path
    new_name = require_param!(:new_name)
    return unless new_name
    entry    = find_entry!(path)
    return unless entry
    entry.rename!(new_name)
    render json: entry_json(entry)
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  rescue RuntimeError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def destroy_entry
    path  = require_param!(:path)
    return unless path
    entry = find_entry!(path)
    return unless entry
    entry.destroy!
    head :no_content
  end

  private

  def load_project
    @project = current_user.projects.find(params[:project_id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'project not found' }, status: :not_found
  end

  def find_entry!(path)
    entry = DirectoryEntry.find_by_project_and_path(@project.id, path.to_s.strip)
    unless entry
      render json: { error: 'not found' }, status: :not_found
      return nil
    end
    entry
  end

  def require_param!(key)
    val = params[key].to_s.strip
    if val.empty?
      render json: { error: "#{key} is required" }, status: :unprocessable_entity
      return nil
    end
    val
  end

  def entry_json(entry)
    { id: entry.id, name: entry.cur_name, path: entry.srcpath, type: entry.ftype }
  end
end
