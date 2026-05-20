class CreateProjectSettings < ActiveRecord::Migration[8.1]
  def change
    create_table :project_settings do |t|
      t.references :project, null: false, foreign_key: true, index: { unique: true }
      t.float   :flush_interval_s, default: 0.8,  null: false
      t.integer :flush_bytes,      default: 20,   null: false
      t.string  :shell_image

      t.timestamps
    end
  end
end
