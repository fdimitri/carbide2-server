# frozen_string_literal: true
require 'digest'
class Blob < ApplicationRecord
  self.primary_key = 'digest'

  # Store `bytes` (an ASCII-8BIT String) and return its SHA-256 digest. This is
  # content-addressed: identical content returns the same digest and does not
  # create a duplicate row. Handles the concurrent-insert race: if two writers
  # store the same digest at once, the loser rescues the unique violation and
  # returns the winner's digest.
  # Delegates to the configured DbfsV2::BlobStore, so the byte backend can be
  # swapped (Postgres bytea today; S3/Ceph behind the same interface) without
  # any caller changing.
  def self.store(bytes)
    DbfsV2.blob_store.put(bytes)
  end

  def content_bytes
    content.b
  end
end
