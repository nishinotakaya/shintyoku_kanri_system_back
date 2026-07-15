class TrelloTask < ApplicationRecord
  validates :trello_card_id, presence: true, uniqueness: true
  validates :title, presence: true

  scope :for_date, ->(date) {
    where("start_date IS NULL OR start_date <= ?", date)
      .where("due_date IS NULL OR due_date >= ?", date)
  }

  scope :for_assignee, ->(name) { where(assignee_name: name) if name.present? }

  # 未着手 + 進行中（完了リスト以外）
  scope :active, -> { where(done: false) }

  # 「完了扱い」のリストか (完了/Done/マージ済み/ゴミ箱)。「検証完了」「検証中」はまだ作業フロー中なので除く。
  def self.done_list?(list_name)
    name = list_name.to_s
    return false if name.include?("検証")
    name.include?("完了") || name.downcase.include?("done") || name.include?("マージ") || name.include?("ゴミ箱")
  end
end
