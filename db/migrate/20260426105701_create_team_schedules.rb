class CreateTeamSchedules < ActiveRecord::Migration[8.0]
  def change
    create_table :team_schedules do |t|
      t.date :date
      t.string :person
      t.string :status
      t.string :location
      t.string :memo
      t.string :year_month

      t.timestamps
    end
    add_index :team_schedules, [:date, :person], unique: true
    add_index :team_schedules, :year_month
  end
end
