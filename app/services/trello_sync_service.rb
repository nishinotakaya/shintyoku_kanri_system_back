class TrelloSyncService
  def self.call
    new.call
  end

  def call
    client = TrelloClient.new
    board = client.fetch_board
    board_name = board["name"]
    trello_lists = client.fetch_lists
    list_name_by_id = trello_lists.each_with_object({}) { |trello_list, map| map[trello_list["id"]] = trello_list["name"] }
    cards = client.fetch_cards

    upserted_ids = []

    TrelloTask.transaction do
      cards.each do |card|
        next if card["closed"]
        upsert(card, board_name, list_name_by_id)
        upserted_ids << card["id"]
      end

      TrelloTask.where.not(trello_card_id: upserted_ids).delete_all if upserted_ids.any?
    end

    upserted_ids.size
  end

  private

  def upsert(card, board_name, list_name_by_id)
    task = TrelloTask.find_or_initialize_by(trello_card_id: card["id"])
    task.title        = card["name"]
    task.description  = card["desc"]
    task.list_name    = list_name_by_id[card["idList"]]
    task.done         = TrelloTask.done_list?(list_name_by_id[card["idList"]])
    task.board_id     = card["idBoard"]
    task.board_name   = board_name
    task.assignee_name = card["members"]&.first&.dig("fullName")
    task.start_date   = extract_date(card["start"])
    task.due_date     = extract_date(card["due"])
    task.url          = card["shortUrl"]
    task.position     = card["pos"]
    task.synced_at    = Time.current
    task.save!
  end

  # Trello の日時は UTC の ISO8601。JST に変換してから日付化しないと深夜期限のカードが1日前にズレる。
  def extract_date(iso_datetime)
    return nil if iso_datetime.blank?
    Time.iso8601(iso_datetime).in_time_zone("Asia/Tokyo").to_date
  rescue ArgumentError, TypeError
    nil
  end
end
