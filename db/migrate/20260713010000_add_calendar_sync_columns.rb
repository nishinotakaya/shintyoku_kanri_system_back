class AddCalendarSyncColumns < ActiveRecord::Migration[8.0]
  def change
    # プライベートTodo⇄Googleカレンダー双方向同期用。
    # 専用カレンダー(勤怠等と混ざらない)のIDをユーザーに、イベントIDを各タスクに保持し重複を防ぐ。
    add_column :users, :private_todo_calendar_id, :string
    add_column :backlog_tasks, :google_event_id, :string
    add_index  :backlog_tasks, :google_event_id
  end
end
