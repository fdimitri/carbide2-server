# ProjectArchive — export/import the on-disk project directory (the PVC mirror
# at /srv/projects/<uuid>) as a single .tar.gz, entries relative to that root.
#
# This is the RAW disk tree, not the DBFS (DirectoryEntry) tree: it round-trips
# everything on the PVC including .git / node_modules / binary files, with no
# FsLoader ignore list. Import extracts to disk and then re-scans into the DBFS
# so the explorer reflects the restored files.
#
# NOTE: this is a FAITHFUL extractor, not a hardened one. Entry names are taken
# as-is (joined under the root); no traversal filtering, no symlink policy, no
# size caps. It is meant to round-trip archives WE produced, run by the same
# (already non-root) user inside the pod. If untrusted archives are ever
# accepted, the extractor must be redesigned for that threat model separately —
# do not mistake this for one that is.
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
      stats = { files: 0, dirs: 0 }

      gz = Zlib::GzipReader.new(src)
      Gem::Package::TarReader.new(gz) do |tar|
        tar.each do |entry|
          target = File.expand_path(File.join(root, entry.full_name))
          if entry.directory?
            FileUtils.mkdir_p(target)
            stats[:dirs] += 1
          elsif entry.file?
            FileUtils.mkdir_p(File.dirname(target))
            File.binwrite(target, entry.read)
            stats[:files] += 1
          end
          # symlink / hardlink / special entry — skipped.
        end
      end
      stats
    ensure
      gz&.close rescue nil
    end
  end
end
