class AddAttendanceScheduleUrlToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :attendance_schedule_url, :string
  end
end
