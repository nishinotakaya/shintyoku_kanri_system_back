class NotionTask < ApplicationRecord
  validates :notion_block_id, presence: true, uniqueness: true
  validates :title, presence: true

  # WBS Excel 書き出し(NotionWbsExcelUpdater)で「修正後」として上書きしうる項目。
  # *_prev 列がこれに対応する(例: :title → title_prev)。
  OVERRIDE_FIELDS = %i[title assignee_name workload start_date end_date progress_rate].freeze

  # NotionWbsExcelUpdater の赤塗り判定で「テンプレと比較できる項目→WbsScheduleCellParser の kind」の対応。
  # title/assignee_name はテンプレ側(E〜H列のみ)に対応するセルが無いため比較対象外(常に「異なる」扱い)。
  TEMPLATE_COMPARABLE_FIELD_KINDS = {
    progress_rate: :rate,
    workload: :number,
    start_date: :date,
    end_date: :date
  }.freeze

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

  # OVERRIDE_FIELDS の1項目について、アプリで編集した「修正後」の値(*_prev)を返す。
  def override_value(field)
    public_send("#{field}_prev")
  end

  # その項目に「修正後」の値が入っているか(数値 0 は上書きとして扱う。nil/空文字だけ不在)。
  def override_present?(field)
    override_value(field).present?
  end

  # wbs_submitted_overrides(提出済スナップショット)と比較するための文字列表現。
  def serialized_override(field)
    value = override_value(field)
    case value
    when Date
      value.to_s
    when Numeric
      value.to_f.to_s
    else
      value.to_s
    end
  end

  # 「修正後」の値があり、かつ最後に提出済にした時点のスナップショットと異なる(＝未提出の変更がある)。
  def unsubmitted_override?(field)
    override_present?(field) && wbs_submitted_overrides[field.to_s] != serialized_override(field)
  end

  # その項目の「修正後」の値が、登録済みテンプレ(WbsTemplateValuesReader が読んだ元の値。
  # template_row は { progress_rate:, workload:, start_date:, end_date: } の Hash)と異なるか。
  # テンプレ未登録・該当WBS行がテンプレに無い場合(template_row が nil)や、比較対象外の項目は
  # 常に true(＝異なる扱い)を返す。
  def template_differs?(field, template_row)
    kind = TEMPLATE_COMPARABLE_FIELD_KINDS[field]
    return true if kind.nil? || template_row.nil?

    !WbsScheduleCellParser.values_equal?(kind, override_value(field), template_row[field])
  end

  # WBS Excel 書き出し(NotionWbsExcelUpdater)でそのセルの背景を赤く塗るか。
  # 「未提出の修正後があり」かつ「テンプレの値と異なる」場合だけ赤くする(テンプレと同じ値なら
  # 出力しても見た目が変わらないため塗らない)。ただし完了扱い(進捗率100%以上)のタスクは
  # 報告対象外として赤塗りしない(値の書き込み自体は行う)。
  def red_cell?(field, template_row)
    return false if effective_progress_rate.to_f >= 1.0

    unsubmitted_override?(field) && template_differs?(field, template_row)
  end

  # 現時点の「修正後」の値をすべて提出済スナップショットとして保存する(=赤塗りを解除する)。
  def mark_overrides_submitted!
    update!(
      wbs_submitted_overrides: OVERRIDE_FIELDS.select { |field| override_present?(field) }
                                               .to_h { |field| [ field.to_s, serialized_override(field) ] }
    )
  end
end
