class AddCalendarPersonsToUsers < ActiveRecord::Migration[8.0]
  def change
    # カレンダーに行を出す人物名の配列(JSON)。nil = 既定(TeamSchedule::DEFAULT_PERSONS)
    add_column :users, :calendar_persons, :text
  end
end
