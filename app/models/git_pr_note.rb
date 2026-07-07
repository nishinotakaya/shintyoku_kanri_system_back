# Backlog に送らない「システム内のみ」の PR メモ/やりとり。
# Git ページの PR 詳細のタブ「システム内」で表示・投稿する（全ユーザーで共有、削除は本人のみ）。
class GitPrNote < ApplicationRecord
  belongs_to :user
  validates :content, presence: true

  scope :for_pr, ->(project_key, repo_name, pr_number) {
    where(project_key: project_key, repo_name: repo_name, pr_number: pr_number).order(:created_at)
  }
end
