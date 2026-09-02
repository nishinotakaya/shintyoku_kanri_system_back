module Api
  module V1
    # 進捗の LINE 報告(汎用)。フロントで組み立てた文面をそのまま西野さんの LINE (LINE_PUSH_TO) へ送る。
    # タマ(Backlog)・リビング(Notion)・テックリーダー(Trello)・手動タスクのどれでも使える。
    # notion_issue_keys が来たら、送信後に該当 NotionTask の *_prev(変更差分)をクリアし、
    # 次回のリビング報告では変更なし扱いにする(notion の view 権限がある人だけ)。
    class LineReportsController < BaseController
      def create
        text = params[:message].to_s.strip
        return render(json: { error: "本文が空です" }, status: :unprocessable_entity) if text.blank?
        unless LineNotifier.push(text)
          return render(json: { error: "LINE送信に失敗しました。LINE設定(チャネルトークン)を確認してください" }, status: :bad_gateway)
        end
        if params[:notion_issue_keys].present? && current_user.can_view_data_source?("notion")
          NotionTask.for_kanban_issue_keys(params[:notion_issue_keys]).each(&:clear_reported_diffs!)
        end
        archive = LineReportArchiver.record(user: current_user, message: text)
        render json: { sent: true }.merge(archive)
      end
    end
  end
end
