class NotionSyncService
  def self.call
    new.call
  end

  def call
    data = NotionClient.new.query_assigned_tasks
    record_map = data["recordMap"] || {}
    block_map  = record_map["block"] || {}
    user_map   = record_map["notion_user"] || {}
    result_ids = data.dig("result", "reducerResults", "collection_group_results", "blockIds") || []

    upserted_ids = []

    NotionTask.transaction do
      result_ids.each do |block_id|
        block = block_map.dig(block_id, "value", "value") || block_map.dig(block_id, "value")
        next if block.nil?
        upsert(block_id, block["properties"] || {}, user_map)
        upserted_ids << block_id
      end

      NotionTask.where.not(notion_block_id: upserted_ids).delete_all if upserted_ids.any?
    end

    upserted_ids.size
  end

  private

  def upsert(block_id, properties, user_map)
    assignee_id, assignee_name = extract_first_person(properties[NotionClient::PROPERTY_IDS[:assignee]], user_map)

    task = NotionTask.find_or_initialize_by(notion_block_id: block_id)
    new_start    = extract_date(properties[NotionClient::PROPERTY_IDS[:start_date]])
    new_end      = extract_date(properties[NotionClient::PROPERTY_IDS[:end_date]])
    new_progress = extract_text(properties[NotionClient::PROPERTY_IDS[:progress_rate]])&.presence&.to_f
    new_status   = extract_text(properties[NotionClient::PROPERTY_IDS[:status]])
    # 修正前(前回同期値)の退避: 既存レコードで値が変わったときだけ、変更前の値を *_prev に保存する。
    task.start_date_prev    = task.start_date    if task.persisted? && task.start_date != new_start
    task.end_date_prev      = task.end_date      if task.persisted? && task.end_date != new_end
    task.progress_rate_prev = task.progress_rate if task.persisted? && task.progress_rate.to_f != new_progress.to_f
    task.status_prev        = task.status        if task.persisted? && task.status != new_status

    task.title              = strip_indent(extract_text(properties[NotionClient::PROPERTY_IDS[:title]]) || "(無題)")
    task.wbs_level          = extract_text(properties[NotionClient::PROPERTY_IDS[:wbs_level]])
    task.parent_task        = extract_text(properties[NotionClient::PROPERTY_IDS[:parent_task]])
    task.assignee_notion_id = assignee_id
    task.assignee_name      = assignee_name
    task.start_date         = new_start
    task.end_date           = new_end
    task.workload           = extract_text(properties[NotionClient::PROPERTY_IDS[:workload]])&.presence&.to_f
    task.progress_rate      = new_progress
    task.status             = new_status
    task.priority           = extract_text(properties[NotionClient::PROPERTY_IDS[:priority]])
    task.note               = extract_text(properties[NotionClient::PROPERTY_IDS[:note]])
    task.synced_at          = Time.current
    task.save!
  end

  def strip_indent(value)
    # WBS インデントの全角スペースを除去
    value.to_s.gsub(/\A[　\s]+/, "")
  end

  def extract_text(prop)
    return nil if prop.nil?
    prop.map { |segment| segment[0] }.join.strip
  end

  def extract_date(prop)
    return nil if prop.nil?
    prop.each do |segment|
      next unless segment[1]
      segment[1].each do |annotation|
        next unless annotation[0] == "d"
        date_str = annotation[1]["start_date"]
        return Date.parse(date_str) if date_str
      end
    end
    nil
  rescue ArgumentError
    nil
  end

  def extract_first_person(prop, user_map)
    return [nil, nil] if prop.nil?
    prop.each do |segment|
      next unless segment[1]
      segment[1].each do |annotation|
        next unless annotation[0] == "u"
        user_id = annotation[1]
        user = user_map.dig(user_id, "value", "value") || user_map.dig(user_id, "value")
        return [user_id, user&.dig("name") || user_id]
      end
    end
    [nil, nil]
  end
end
