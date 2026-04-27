# Backlog REST API v2 からイシューを取得して BacklogTask に同期する。
# 1回目: 全件 create。2回目以降: 既存は update、新規は create。
class BacklogSyncService
  def initialize(user)
    @user = user
    @setting = user.backlog_setting
    raise "バックログ設定がありません。設定画面で API キーを保存してください。" unless @setting&.api_key.present?
  end

  def call
    client = BacklogClient.new(@setting)
    name_filter = @setting.assignee_name_filter.to_s.strip
    overwrite_mode = name_filter.present?

    issues =
      if overwrite_mode
        uid = client.find_user_id_by_name(name_filter)
        raise "Backlog で「#{name_filter}」のユーザーが見つかりません。設定中の API キーが「#{name_filter}」本人のものか、または admin 権限を持つ API キーかを確認してください。" unless uid
        client.fetch_issues_for([ uid ], status_ids: [ 1, 2, 3, 4 ])
      else
        client.fetch_issues(status_ids: [ 1, 2, 3, 4 ])
      end

    synced = []
    ActiveRecord::Base.transaction do
      issues.each do |issue|
        task = @user.backlog_tasks.find_or_initialize_by(issue_key: issue["issueKey"])
        task.source = "backlog" if task.new_record?
        task.summary = issue["summary"]
        task.status_id = issue.dig("status", "id")
        task.status_name = issue.dig("status", "name")
        task.created_on = parse_date(issue["created"])
        task.due_date = parse_date(issue["dueDate"])
        task.start_date = parse_date(issue["startDate"])
        task.end_date = parse_date(issue["dueDate"])
        task.assignee_name = issue.dig("assignee", "name")
        task.assignee_id = issue.dig("assignee", "id")
        task.url = "#{@setting.backlog_url.chomp('/')}/view/#{issue['issueKey']}"

        # 完了ステータス(4)なら completed_on を記録
        if task.status_id == 4 && task.completed_on.nil?
          task.completed_on = parse_date(issue["updated"]) || Date.current
        elsif task.status_id != 4
          task.completed_on = nil
        end

        task.save!
        synced << task
      end

      # 上書き同期: フィルタ設定時のみ、今回取得に含まれなかった backlog 由来タスクは削除
      if overwrite_mode
        fresh_keys = issues.map { |i| i["issueKey"] }
        @user.backlog_tasks.where(source: "backlog").where.not(issue_key: fresh_keys).destroy_all
      end
    end

    synced
  end

  private

  def parse_date(val)
    return nil if val.blank?
    Date.parse(val.to_s)
  rescue
    nil
  end
end
