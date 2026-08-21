# 進捗管理(/progress)のワークスペース。ユーザーごとに backlog_tasks を束ねる箱。
# デフォルトで Wing(backlog連携)/リビング(Notion連携)/テックリーダーズ/プライベート の
# 4個(builtin)を持ち、ユーザーは追加でワークスペースを作成できる。
class ProgressWorkspace < ApplicationRecord
  belongs_to :user
  has_many :backlog_tasks, foreign_key: :progress_workspace_id, dependent: :nullify

  SOURCE_TYPES = %w[backlog notion trello manual].freeze

  validates :name, presence: true

  DEFAULTS = [
    { name: "Wing", source_type: "backlog" },
    { name: "リビング", source_type: "notion" },
    { name: "テックリーダーズ", source_type: "trello" },
    # ReRe は西野さん・川村さんだけが使う案件なので既定では作らない。必要な人は ＋ から追加する
    { name: "プライベート", source_type: "manual" }
  ].freeze

  # ユーザーに builtin ワークスペースが1件も無ければ DEFAULTS を position 順に作成する。冪等。
  def self.ensure_defaults!(user)
    return if user.progress_workspaces.where(builtin: true).exists?

    DEFAULTS.each_with_index do |default_workspace, index|
      user.progress_workspaces.create!(
        name: default_workspace[:name],
        source_type: default_workspace[:source_type],
        builtin: true,
        position: index
      )
    end
  end

  def as_payload
    { id: id, name: name, source_type: source_type, builtin: builtin, position: position }
  end
end
