# frozen_string_literal: true
module DbfsV2
  # BranchView — a Store bound to one project branch (ADR-042).
  #
  # Every branch-aware Store method is called with `branch:` forced to this
  # branch, so code written against a Store for main's tree — the flusher, the
  # watcher, the loader, ProjectFs.ensure_* — runs unchanged against a project
  # branch's tree. Anything else falls through to the Store. A view is bound:
  # a `branch:` the caller passes is replaced, not honoured.
  class BranchView
    BRANCHED = %i[
      find find_any resolve stat list tree
      create_file create_folder create_symlink delete restore move adopt!
      read write write_blob commit_blob head_blob_digest text_heads
      merge merge_preview branch branches delete_branch dag dag_condensed
    ].freeze

    # `branch` is Store#branch (create a content branch); the bound name is
    # `branch_name`.
    attr_reader :store, :branch_name

    def initialize(store, branch)
      @store  = store
      @branch_name = branch.to_s
    end

    def project_id = @store.project_id
    def main?      = @branch_name == Branch::MAIN

    BRANCHED.each do |m|
      define_method(m) do |*args, **kw, &blk|
        kw[:branch] = @branch_name
        @store.public_send(m, *args, **kw, &blk)
      end
    end

    def locate(path, _branch = nil, **kw) = @store.locate(path, @branch_name, **kw)

    def for_branch(name) = @store.for_branch(name)

    def method_missing(m, *args, **kw, &blk)
      return @store.public_send(m, *args, **kw, &blk) if @store.respond_to?(m)
      super
    end

    def respond_to_missing?(m, include_private = false) = @store.respond_to?(m, include_private) || super
  end
end
