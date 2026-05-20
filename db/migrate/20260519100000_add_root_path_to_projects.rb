class AddRootPathToProjects < ActiveRecord::Migration[8.0]
  def change
    add_column :projects, :root_path, :string
  end
end
