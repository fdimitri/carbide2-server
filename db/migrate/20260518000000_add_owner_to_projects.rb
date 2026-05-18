class AddOwnerToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :user_id, :integer, null: true
    add_column :projects, :description, :text
    add_index  :projects, :user_id
  end
end
