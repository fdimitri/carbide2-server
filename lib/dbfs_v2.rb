# frozen_string_literal: true
# DBFS v2 — per-file DAG revision store. Loads the library in dependency order.
#
# Required explicitly (not autoloaded) by both processes that use it:
#   * Rails:  config/initializers/dbfs_v2.rb
#   * worker: worker/ar_boot.rb
# lib/dbfs_v2 is excluded from Zeitwerk (config/application.rb) because several
# files define more than one constant (blob_store.rb, errors.rb, version.rb).
#
# The Active Record models (FileNode, Branch, Revision, Keyframe, Blob) live in
# app/models and are resolved at call time, so load order against them does not
# matter.
require 'securerandom'
require 'json'

require_relative 'dbfs_v2/version'
require_relative 'dbfs_v2/errors'
require_relative 'dbfs_v2/clock'
require_relative 'dbfs_v2/events'
require_relative 'dbfs_v2/buffer'
require_relative 'dbfs_v2/delta'
require_relative 'dbfs_v2/myers'
require_relative 'dbfs_v2/transform'
require_relative 'dbfs_v2/document_cache'
require_relative 'dbfs_v2/chain'
require_relative 'dbfs_v2/content'
require_relative 'dbfs_v2/diff3'
require_relative 'dbfs_v2/merge'
require_relative 'dbfs_v2/rebase'
require_relative 'dbfs_v2/blob_store'
require_relative 'dbfs_v2/blob_cache'
require_relative 'dbfs_v2/caching_blob_store'
require_relative 'dbfs_v2/s3_blob_store'
require_relative 'dbfs_v2/blob_io'
require_relative 'dbfs_v2/blob_cursor'
require_relative 'dbfs_v2/ingest'
require_relative 'dbfs_v2/graph'
require_relative 'dbfs_v2/branch_set'
require_relative 'dbfs_v2/project_state'
require_relative 'dbfs_v2/project_merge'
require_relative 'dbfs_v2/store'
require_relative 'dbfs_v2/flusher'
require_relative 'dbfs_v2/watcher'
