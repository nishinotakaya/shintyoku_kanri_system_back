# 上司報告用サマリ（月×課題）の手入力データ。
# 備考（note）と状態推移の上書き（status_override）を保持する。
# 概要・開始日・処理済日・完了日は BacklogActivity から自動算出するため、ここには持たない。
class BacklogSummaryNote < ApplicationRecord
  belongs_to :user

  validates :month, :issue_key, presence: true
  validates :issue_key, uniqueness: { scope: [ :user_id, :month ] }
end
