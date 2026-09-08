# ProjectArchive — export/import the on-disk project directory (the PVC mirror
# at /srv/projects/<uuid>) as a single .tar.gz, entries relative to that root.
#
# This is the RAW disk tree, not the DBFS (DirectoryEntry) tree: it round-trips
# everything on the PVC including .git / node_modules / binary files, with no
# FsLoader ignore list. Import extracts to disk and then re-scans into the DBFS
# so the explorer reflects the restored files.
#
# Sanitization: tar entry names are arbitrary strings (absolute paths and `..`
# are permitted by the format), so both directions normalize against the root
# and reject traversal. Symlinks are skipped (not archived, not followed) for
# now — preserving them faithfully needs a symlink policy that is out of scope
# for this first cut.
require 'zlib'
require 'find'
require 'rubygems/package'

class ProjectArchive
  class << self
    # Stream a .tar.gz of +root_path+ (entries relative to it) into +out+.
    def export_to(root_path, out)
      root = File.expand_path(root_path)
      gz  = Zlib::GzipWriter.new(out)
      Gem::Package::TarWriter.new(gz) do |tar|
        Find.find(root) do |path|
          next if path == root
          rel = path[root.length + 1..].to_s
          next if rel.empty?

          if File.directory?(path)
            tar.mkdir(rel, 0o755)
          elsif File.file?(path)
            mode = File.stat(path).mode & 0o7777
            tar.add_file_simple(rel, mode, File.size(path)) do |entry_io|
              File.open(path, 'rb') { |f| IO.copy_stream(f, entry_io) }
            end
          end
          # symlinks and special files (sockets, fifos, devices) are skipped.
        end
      end
      gz.finish
    end

    # Extract a .tar.gz from +src+ into +root_path+. Returns a stats hash.
    def import_from(src, root_path)
      root = File.expand_path(root_path)
      FileUtils.mkdir_p(root)
      stats = { files: 0, dirs: 0, skipped: 0 }

      gz = Zlib::GzipReader.new(src)
      Gem::Package::TarReader.new(gz) do |tar|
        tar.each do |entry|
          rel = safe_rel(entry.full_name)
          next if rel.empty?

          target = File.expand_path(File.join(root, rel))
          unless target == root || target.start_with?(root + '/')
            stats[:skipped] += 1
            next
          end

          if entry.directory?
            FileUtils.mkdir_p(target)
            stats[:dirs] += 1
          elsif entry.file?
            FileUtils.mkdir_p(File.dirname(target))
            File.binwrite(target, entry.read)
            stats[:files] += 1
          else
            # symlink / hardlink / special entry — skip, don't follow.
            stats[:skipped] += 1
          end
        end
      end
      stats
    ensure
      gz&.close rescue nil
    end

    private

    # Strip leading slashes and drop `.`/`..` components (zip-slip guard).
    def safe_rel(name)
      name.to_s.gsub('\\', '/').sub(%r{\A/+}, '').split('/')
          .reject { |p| p.empty? || p == '.' || p == '..' }
          .join('/')
    end
  end
end
