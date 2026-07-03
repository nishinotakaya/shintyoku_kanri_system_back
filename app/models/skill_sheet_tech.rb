class SkillSheetTech < ApplicationRecord
  # "tech" は既定で "teches" に複数形化されてしまうため明示する。
  self.table_name = "skill_sheet_techs"

  belongs_to :skill_sheet, inverse_of: :techs

  CATEGORIES = %w[language framework db server_os tool].freeze
  CATEGORY_LABELS = {
    "language"  => "言語",
    "framework" => "FW・MW",
    "db"        => "DB",
    "server_os" => "サーバOS",
    "tool"      => "ツール"
  }.freeze

  def as_payload
    {
      id: id,
      category: category,
      category_label: CATEGORY_LABELS[category] || category,
      name: name,
      version: version,
      months_used: months_used,
      experience_label: experience_label,
      last_used_on: last_used_on
    }
  end

  # months_used を「X年Yヶ月」表記に。
  def experience_label
    return "" if months_used.to_i <= 0
    years = months_used / 12
    months = months_used % 12
    [ years.positive? ? "#{years}年" : nil, months.positive? ? "#{months}ヶ月" : nil ].compact.join
  end
end
