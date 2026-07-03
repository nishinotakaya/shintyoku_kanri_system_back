# Backlog の活動履歴（コメント / ステータス変更 / コミット参照）を1行ずつ保存する。
# 川村さんの「対応ログ」を月次で可視化するための一次データ。
class BacklogActivity < ApplicationRecord
  belongs_to :user

  TYPE_LABELS = {
    "comment"  => "報告/調整",
    "status"   => "状態変更",
    "commit"   => "コミット",
    "assigner" => "担当変更"
  }.freeze

  scope :for_month, ->(month) { where(month: month) }
  scope :recent_first, -> { order(occurred_on: :desc, activity_id: :desc) }

  # 月 → サマリ（関与課題数 / コミット数 / 報告調整数 / 状態変更数）を集計して返す。
  def self.monthly_summary(user)
    scope = where(user_id: user.id)
    scope.distinct.pluck(:month).compact.sort.map do |month|
      rows = scope.where(month: month)
      {
        month: month,
        issue_count: rows.distinct.count(:issue_key),
        commit_count: rows.where(activity_type: "commit").count,
        report_count: rows.where(activity_type: "comment").count,
        status_count: rows.where(activity_type: "status").count
      }
    end
  end
end
