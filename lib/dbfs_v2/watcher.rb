# frozen_string_literal: true
require 'tmpdir'

module DbfsV2
  # Watcher — inotify sync from the working area (the PVC) back into the DBFS.
  #
  # Two content types, two mechanisms:
  #
  #   * TEXT  — absorbed as a `setContents` revision (loose sync; external tools
  #     can't express line/char deltas). Small reads; the write window is tiny.
  #   * BINARY — routed through DbfsV2::Ingest (the one ingest function). The
  #     read is guarded: the inotify watch is held for the duration, and any
  #     IN_MODIFY / IN_CLOSE_WRITE / move event for the path during the read
  #     DISCARDS the read, so the newer state is ingested instead. An
  #     intermediate state overwritten mid-read is accepted as lost (#28).
  #
  # IN_Q_OVERFLOW marks the tree dirty for a later reconcile.
  class Watcher
    # Bounded rerun on discard: a hot file that never quiesces must not spin.
    MAX_INGEST_ATTEMPTS = 3

    def initialize(store, root_path, cache: nil, blob_store: nil, staging_dir: nil)
      @store = store
      @root_path = root_path.to_s.chomp('/')
      # Cache/staging default OUTSIDE the watched tree (a cache inside it would be
      # re-ingested by this very watcher).
      @cache = cache || BlobCache.new(File.join(Dir.tmpdir, "dbfs2-cache-#{store.project_id}"))
      @staging_dir = staging_dir || @cache.root
      @blob_store = blob_store || DbfsV2.blob_store
      @suppress = {}
      @pending = Hash.new(0)   # abs path => events seen since last drain
      @reading = {}            # abs path => true while an ingest read is in flight
      @changed = {}            # abs path => a modifying event arrived during the read
      @overflowed = false
    end

    # Begin watching. Returns self, or nil if rb-inotify is unavailable.
    def start!
      require 'rb-inotify'
      @notifier = INotify::Notifier.new
      add_watches_recursive(@root_path)
      self
    rescue LoadError
      warn 'DbfsV2::Watcher: rb-inotify not installed; skipping watch'
      nil
    end

    # Pump one batch of events (the caller's event loop calls this).
    def process
      @notifier&.process
    end

    def overflowed? = @overflowed

    # Guard handed to Ingest: drains pending events for the path at read start,
    # then reports whether a modifying event arrived while the read was running.
    class ReadGuard
      def initialize(watcher, abs)
        @watcher = watcher
        @abs = abs
      end

      def on_read_start
        @watcher.send(:advance_to_read_start, @abs)
      end

      def changed?
        @watcher.send(:read_changed?, @abs)
      end
    end

    private

    def add_watches_recursive(dir)
      return unless File.directory?(dir)
      @notifier.watch(dir, :close_write, :create, :moved_to, :delete, :moved_from) { |e| handle(e) }
      Dir.children(dir).each do |name|
        sub = File.join(dir, name)
        next if File.symlink?(sub)
        add_watches_recursive(sub) if File.directory?(sub)
      end
    end

    def handle(event)
      if event.flags.include?(:q_overflow)
        @overflowed = true
        warn "[DbfsV2::Watcher] inotify queue overflow — marking tree dirty for reconcile"
        return
      end

      abs = event.absolute_name
      return unless abs.start_with?(@root_path + '/')
      return if @suppress[abs]

      # Every event for a path is noted, whether or not we act on it — that is
      # what lets a read in flight see that the file moved under it.
      note_event(abs)

      srcpath = abs[@root_path.length..]
      srcpath = "/#{srcpath}" unless srcpath.start_with?('/')

      if event.flags.include?(:delete) || event.flags.include?(:moved_from)
        @store.delete(srcpath)
        return
      end

      return unless event.flags.include?(:close_write) || event.flags.include?(:moved_to)
      return unless File.file?(abs)

      if self.class.binary_file?(abs)
        ingest_binary(abs, srcpath)
        return
      end

      ingest_text(abs, srcpath)
    end

    public

    # Content sniff shared by every consumer that decides text vs binary for a
    # file on disk: a NUL in the first 8 KiB, or bytes that are not valid UTF-8
    # (so Latin-1 and friends are preserved byte-for-byte rather than lossily
    # transcoded through the text path).
    def self.binary_file?(abs)
      raw = File.binread(abs, [File.size(abs), 8192].min).to_s
      binary_bytes?(raw)
    end

    def self.binary_bytes?(raw)
      raw = raw.to_s.b
      raw.include?("\x00".b) || !raw.dup.force_encoding('UTF-8').valid_encoding?
    end

    # --- binary: one ingest function, guarded read --------------------------
    #
    # Public so an event-loop adapter (the carbide2 worker's VfsWatcher) can run
    # the same absorb logic from its own inotify pump. `guard_factory` builds a
    # fresh guard per attempt; the default is this watcher's ReadGuard, which
    # only sees events this watcher's own #handle has noted.
    def ingest_binary(abs, srcpath, guard_factory: nil)
      guard_factory ||= ->(path) { ReadGuard.new(self, path) }
      # Ensure a binary node exists (resurrect/create/promote on first sight).
      node = @store.find(srcpath)
      if node.nil?
        @store.create_file(srcpath, binary: true)
      else
        target = node.resolve || node
        target.update_columns(binary: true, updated_at: Time.current) unless target.binary?
      end

      res = nil
      MAX_INGEST_ATTEMPTS.times do
        res = DbfsV2::Ingest.call(
          store: @store, path: srcpath, source_path: abs,
          staging_dir: @staging_dir, cache: @cache, blob_store: @blob_store,
          guard: guard_factory.call(abs)
        )
        break unless res[:status] == :discarded  # the newer state is on disk now
      end
      res
    end

    # --- text: setContents (loose sync) -------------------------------------

    # Returns { status: :created | :changed | :noop, node:, revisions: [...] }.
    # Public for the same reason as #ingest_binary.
    #
    # `base_revision_id` is the revision the file on disk was last written from
    # (the flusher knows it). When given, the external setContents is anchored
    # there, so it is diffed against what the external writer actually saw and
    # OT-merged with anything written to DBFS since — instead of being diffed
    # against the current head, which would silently revert those writes.
    # Overlaps raise ConflictError (decisions #16). nil keeps the blind
    # head-relative behavior.
    def ingest_text(abs, srcpath, base_revision_id: nil)
      node = @store.find(srcpath)

      if node.nil?
        content = File.read(abs, encoding: 'UTF-8', invalid: :replace, undef: :replace, replace: '')
        created = @store.create_file(srcpath, content: content)
        return { status: :created, node: created, revisions: [] }
      end

      target = node.resolve || node
      if target.binary?
        # binary -> text on disk: demote so a setContents is valid.
        target.update_columns(binary: false, updated_at: Time.current)
      end
      current = @store.read(target.path)
      content = File.read(abs, encoding: 'UTF-8', invalid: :replace, undef: :replace, replace: '')
      return { status: :noop, node: target, revisions: [] } if content == current

      revs = @store.write(target.path, Delta.new('setContents', { data: content }),
                          base_revision_id: base_revision_id, user_id: nil)
      { status: :changed, node: target, revisions: revs }
    end

    private

    # --- read-in-flight bookkeeping -----------------------------------------

    def note_event(abs)
      @pending[abs] += 1
      @changed[abs] = true if @reading[abs]
    end

    # Drain the path's queued events and arm the read window.
    def advance_to_read_start(abs)
      @pending[abs] = 0
      @changed[abs] = false
      @reading[abs] = true
    end

    # End the read window and report whether a modifying event arrived during it.
    def read_changed?(abs)
      @reading[abs] = false
      !!@changed[abs]
    end

    # Mark a path as written-by-us so a flush doesn't echo back. (Consumers set
    # this around Flusher writes.)
    def suppress!(abs)
      @suppress[abs] = true
      yield
    ensure
      @suppress.delete(abs)
    end
  end
end
