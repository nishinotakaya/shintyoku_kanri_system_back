class AddLocalSaveDirToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :local_save_dir, :string
  end
end
