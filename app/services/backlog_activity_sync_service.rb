# Backlog の活動履歴（コメント/ステータス変更/コミット）を取得して BacklogActivity に同期する。
# assignee_name_filter（例: 川村 卓也）が設定されていれば、そのユーザーの活動を保存する。
class BacklogActivitySyncService
  STATUS_NAMES = { "1" => "未対応", "2" => "処理中", "3" => "処理済み", "4" => "完了" }.freeze

  def initialize(user)
    @user = user
    @setting = user.backlog_setting
    raise "バックログ設定がありません。" unless @setting&.api_key.present?
  end

  def call
    client = BacklogClient.new(@setting)
    name_filter = @setting.assignee_name_filter.to_s.strip
    backlog_user_id =
      if name_filter.present?
        client.find_user_id_by_name(name_filter) or
          raise "Backlog で「#{name_filter}」のユーザーが見つかりません。"
      else
        @setting.user_backlog_id
      end

    activities = client.fetch_user_activities(backlog_user_id)
    synced = 0
    ActiveRecord::Base.transaction do
      activities.each do |activity|
        content_data = activity["content"] || {}
        issue_key = "#{activity.dig('project', 'projectKey')}-#{content_data['key_id']}"
        rec = @user.backlog_activities.find_or_initialize_by(activity_id: activity["id"])
        rec.assign_attributes(
          project_key:   activity.dig("project", "projectKey"),
          issue_key:     issue_key,
          summary:       content_data["summary"],
          activity_type: classify(content_data),
          content:       extract_content(content_data),
          occurred_on:   parse_date(activity["created"]),
          month:         activity["created"].to_s[0, 7],
          url:           "#{@setting.backlog_url.chomp('/')}/view/#{issue_key}"
        )
        rec.save!
        synced += 1
      end
    end

    sync_completions(client, backlog_user_id)
    synced
  end

  private

  # 完了日(done_on)を Backlog から確実に取り込む。
  # 活動フィードに残らない古い完了も拾えるよう、サマリ対象課題のうち「現在 完了」のものは
  # changeLog から完了日を取得して backlog_completions に保存する。
  def sync_completions(client, backlog_user_id)
    issue_keys = @user.backlog_activities.distinct.pluck(:issue_key).compact
    return if issue_keys.empty?

    completed_keys = client.fetch_issues_for([ backlog_user_id ], status_ids: [ 4 ]).map { |issue| issue["issueKey"] }
    (completed_keys & issue_keys).each do |issue_key|
      completed_on = client.fetch_issue_completion_date(issue_key) or next
      record = @user.backlog_completions.find_or_initialize_by(issue_key: issue_key)
      record.update!(completed_on: completed_on, synced_at: Time.current)
    rescue => e
      Rails.logger.warn("[BacklogCompletion] #{issue_key} の完了日取得に失敗: #{e.message}")
    end
  end

  def changes_of(content_data)
    Array(content_data["changes"])
  end

  # コミット参照あり→commit / ステータス変更あり→status / 担当変更→assigner / 本文あり→comment
  def classify(content_data)
    changes = changes_of(content_data)
    return "commit"   if changes.any? { |c| c["field"] == "commit" }
    return "status"   if changes.any? { |c| c["field"] == "status" }
    return "assigner" if changes.any? { |c| c["field"] == "assigner" }
    "comment"
  end

  def extract_content(content_data)
    comment = content_data.dig("comment", "content").to_s.strip
    changes = changes_of(content_data)
    status_change = changes.find { |c| c["field"] == "status" }
    if status_change
      old = STATUS_NAMES[status_change["old_value"].to_s] || status_change["old_value"]
      neu = STATUS_NAMES[status_change["new_value"].to_s] || status_change["new_value"]
      "#{old}→#{neu}"
    else
      comment
    end
  end

  def parse_date(val)
    return nil if val.blank?
    Date.parse(val.to_s)
  rescue
    nil
  end
end
