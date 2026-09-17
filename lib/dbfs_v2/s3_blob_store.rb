# frozen_string_literal: true
require 'digest'

module DbfsV2
  # S3BlobStore — S3-shape byte store (MinIO, AWS S3, R2, Ceph RGW).
  #
  # The S3 client is INJECTED, so the store is testable without the network (a
  # fake client in tests) and does not hard-depend on aws-sdk-s3 at load time.
  # If built from config with no client, it lazily constructs an
  # `Aws::S3::Client` (which requires the gem).
  #
  # Keys are sharded by digest (`<prefix><ab>/<cd>/<sha256>`) — a flat prefix is
  # a hot key space on a single drive.
  #
  # Do NOT enable bucket versioning on the target bucket: content-addressing is
  # already the versioning, and S3 versioning would multiply storage and defeat
  # dedup.
  class S3BlobStore < BlobStore
    attr_reader :bucket, :prefix

    def initialize(client: nil, bucket:, prefix: 'blobs/', **client_opts)
      @client = client
      @client_opts = client_opts
      @bucket = bucket
      @prefix = prefix.to_s
    end

    def put(bytes)
      bytes = bytes.to_s.b
      digest = Digest::SHA256.hexdigest(bytes)
      client.put_object(bucket: @bucket, key: key(digest), body: bytes)
      digest
    end

    def get(digest)
      client.get_object(bucket: @bucket, key: key(digest)).body.read.to_s.b
    end

    def exist?(digest)
      client.head_object(bucket: @bucket, key: key(digest))
      true
    rescue StandardError
      false
    end

    def size(digest)
      client.head_object(bucket: @bucket, key: key(digest)).content_length.to_i
    rescue StandardError
      nil
    end

    def delete(digest)
      client.delete_object(bucket: @bucket, key: key(digest))
    end

    # Native S3 Range GET — no whole-object download.
    def read_range(digest, offset, length)
      off = [offset.to_i, 0].max
      range = length.nil? || length.to_i <= 0 ? "bytes=#{off}-" : "bytes=#{off}-#{off + length.to_i - 1}"
      client.get_object(bucket: @bucket, key: key(digest), range: range).body.read.to_s.b
    end

    def key(digest) = "#{@prefix}#{digest[0, 2]}/#{digest[2, 2]}/#{digest}"

    private

    def client
      @client ||= build_aws_client!
    end

    def build_aws_client!
      require 'aws-sdk-s3'
      Aws::S3::Client.new(**@client_opts)
    rescue LoadError
      raise 'aws-sdk-s3 is not available; pass an explicit client: to S3BlobStore'
    end
  end
end
