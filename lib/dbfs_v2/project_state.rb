# frozen_string_literal: true
module DbfsV2
  # A project tree as a project-DAG node sees it: path → identity → revision.
  # Built by ProjectDag.view from a stored node, never by folding FileEvents.
  class ProjectState
    Entry = Struct.new(:file_node_id, :path, :ftype, :branch, :revision_id, keyword_init: true) do
      def folder? = ftype == 'folder'
      def to_h    = { id: file_node_id, path: path, ftype: ftype, branch: branch, revision_id: revision_id }
    end

    attr_reader :project_id, :entries

    def initialize(project_id:, entries:)
      @project_id = project_id
      @entries    = entries.freeze
    end

    def [](path)  = @entries.values.find { |e| e.path == path }
    def paths     = @entries.values.map(&:path).sort
    def files     = @entries.values.reject(&:folder?)
    def size      = @entries.size
    def include?(path) = !self[path].nil?

    def read(path)
      e = self[path]
      raise "no such file in state: #{path}" unless e
      return nil if e.folder?
      return '' unless e.revision_id
      Content.at(FileNode.find(e.file_node_id), e.revision_id)
    end

    def diff(other)
      out = { added: [], removed: [], renamed: [], modified: [] }
      other.entries.each do |id, e|
        mine = @entries[id]
        if mine.nil?
          out[:added] << e
        else
          out[:renamed]  << { from: mine.path, to: e.path, entry: e } if mine.path != e.path
          out[:modified] << { from: mine.revision_id, to: e.revision_id, entry: e } if mine.revision_id != e.revision_id
        end
      end
      @entries.each { |id, e| out[:removed] << e unless other.entries.key?(id) }
      out
    end

    def to_h
      { project_id: @project_id, entries: @entries.values.sort_by(&:path).map(&:to_h) }
    end
  end
end
