class NotionTask < ApplicationRecord
  validates :notion_block_id, presence: true, uniqueness: true
  validates :title, presence: true

  scope :for_date, ->(date) {
    where("start_date IS NULL OR start_date <= ?", date)
      .where("end_date IS NULL OR end_date >= ?", date)
  }

  scope :for_assignee, ->(name) { where(assignee_name: name) if name.present? }

  # 未着手 + 進行中（完了以外）。未設定 (NULL/空) も active 扱い
  scope :active, -> { where("status IS NULL OR status = '' OR status != ?", "完了") }

  # 進捗カンバン(BacklogTask)側の issue_key 「N-<ハイフン無しblock_id>」から逆引きする
  scope :for_kanban_issue_keys, ->(issue_keys) {
    block_ids = Array(issue_keys).map { |key| key.to_s.delete_prefix("N-").strip.downcase }.reject(&:empty?)
    block_ids.empty? ? none : where("REPLACE(notion_block_id, '-', '') IN (?)", block_ids)
  }

  # Notion 上でこのタスクを開く URL (フロントのリビングタスクリンクと同じ形式)
  def url
    "https://www.notion.so/#{NotionClient::PAGE_ID.delete('-')}?v=#{NotionClient::COLLECTION_VIEW_ID.delete('-')}&p=#{notion_block_id.to_s.delete('-')}&pm=s"
  end

  # LINE 報告済みの変更差分(*_prev)をクリアする。次回の報告では「変更なし」として現在値だけが出る。
  # 注意: シート書き出し(NotionTaskExporter)の「修正前」列も未報告の変更だけが載るようになる。
  def clear_reported_diffs!
    update!(start_date_prev: nil, end_date_prev: nil, progress_rate_prev: nil, status_prev: nil)
  end

  # WBS Excel 書き出し(NotionWbsExcelUpdater)向けの実効値。
  # *_prev(アプリで編集した「修正後」の値)が入っていればそれを、無ければ元の値(Notion 同期値)を返す。
  def effective_title
    title_prev.presence || title
  end

  def effective_assignee_name
    assignee_name_prev.presence || assignee_name
  end

  def effective_workload
    workload_prev.presence || workload
  end

  def effective_start_date
    start_date_prev.presence || start_date
  end

  def effective_end_date
    end_date_prev.presence || end_date
  end

  def effective_progress_rate
    progress_rate_prev.presence || progress_rate
  end

  def effective_status
    status_prev.presence || status
  end
end
