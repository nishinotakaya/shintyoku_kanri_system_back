# カレンダーの人物行(出社/リモート等の予定)。スプレッドシートから取り込む。
class TeamSchedule < ApplicationRecord
  # 誰も設定していないときに行を出す既定メンバー(スプレッドシートに列がある人)
  DEFAULT_PERSONS = %w[西野 川村 大隅 土倉 岩切].freeze

  # 既定で全員分の予定を見るメンバー。それ以外の人は自分の予定だけが既定になる。
  FULL_CALENDAR_PERSONS = %w[西野 川村].freeze

  # 管理画面で選べる人物名。既定メンバー + 取込データに現れた人物。
  def self.selectable_persons
    (DEFAULT_PERSONS + distinct.where.not(person: [ nil, "" ]).pluck(:person)).uniq
  end
end
