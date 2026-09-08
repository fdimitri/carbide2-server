# ProjectArchive — stream an on-disk directory (or the whole project root) as a
# single .tar.gz, entries relative to that directory.
#
# Export-only. Import goes through the existing fs/upload endpoint
# (ArchiveImporter), which extracts a .tar.gz into a destination dir — project
# "import" is just an upload targeted at '/'. So there is deliberately no
# extractor here: one tar direction, one place.
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
  end
end
