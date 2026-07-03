module Api
  module V1
    # スキルシート機能。
    # アクセス権: current_user.can_use?(:skill_sheet) (admin は常に可)。
    # 対象ユーザーのスコープ: admin=全員 / サブ管理者=managee / 一般=自分のみ。
    class SkillSheetsController < BaseController
      before_action :ensure_feature
      rescue_from ActiveRecord::RecordNotFound do
        render json: { error: "対象が見つかりません" }, status: :not_found
      end

      # GET /api/v1/skill_sheets  自分が管理できるユーザーのスキルシート一覧
      def index
        sheets = SkillSheet.where(user_id: current_user.manageable_user_ids)
                           .includes(:projects, :user)
        render json: sheets.map { |s| s.as_payload.merge(user: user_brief(s.user)) }
      end

      # GET /api/v1/skill_sheets/targets  対象に選べるユーザー一覧
      def targets
        users = User.where(id: current_user.manageable_user_ids).order(:id)
        sheet_user_ids = SkillSheet.where(user_id: users.map(&:id)).pluck(:user_id).to_set
        render json: users.map { |u|
          user_brief(u).merge(
            has_sheet: sheet_user_ids.include?(u.id),
            can_generate: u.feature_flags.to_h["skill_sheet_generate"] == true
          )
        }
      end

      # GET /api/v1/skill_sheets/tech_candidates
      # 技術欄(使用言語/DB/サーバOS/FW・MW・ツール)のセレクト候補。
      # マスタ + 管理スコープ内で既に登録された skill_sheet_techs の名称を合成。
      def tech_candidates
        sheet_ids = SkillSheet.where(user_id: current_user.manageable_user_ids).pluck(:id)
        techs = SkillSheetTech.where(skill_sheet_id: sheet_ids).pluck(:category, :name, :version)
        extra = SkillSheetTechCatalog.extra_from_techs(techs)
        render json: SkillSheetTechCatalog.candidates(extra)
      end

      # GET /api/v1/skill_sheets/:id
      def show
        sheet = find_sheet or return
        render json: sheet.as_payload.merge(user: user_brief(sheet.user))
      end

      # POST /api/v1/skill_sheets  { user_id }  対象ユーザーの空シートを作成 (既存があれば返す)
      def create
        target = resolve_target_user(params[:user_id]) or return
        sheet = target.skill_sheet || target.create_skill_sheet!(
          engineer_name: target.display_name,
          skills: target.dev_language
        )
        render json: sheet.as_payload.merge(user: user_brief(target))
      rescue => e
        render_error(e.message)
      end

      # POST /api/v1/skill_sheets/import  { user_id, spreadsheet_url }
      def import
        target = resolve_target_user(params[:user_id]) or return
        url = params[:spreadsheet_url].to_s.strip
        return render_error("スプレッドシートの URL を入力してください") if url.empty?

        result = SkillSheetImporter.new(spreadsheet_url: url, user: current_user).call
        sheet = target.skill_sheet || target.build_skill_sheet
        sheet.assign_attributes(
          spreadsheet_url: url,
          spreadsheet_id: result[:spreadsheet_id],
          gid: result[:gid],
          raw_content: result[:raw_content]
        )
        sheet.save!
        sheet.apply_import!(result[:structured]) # UPSERT: Backlog生成分(source=backlog)は消さず、import分のみ入替
        sheet.capture_before_snapshot! # 読み込んだ原本を「添削前(Before)」として保持
        render json: sheet.as_payload.merge(user: user_brief(target))
      rescue => e
        render_error(e.message)
      end

      # POST /api/v1/skill_sheets/:id/set_before  現在の内容を Before として保存
      def set_before
        sheet = find_sheet or return
        sheet.capture_before_snapshot!
        render json: { before_snapshot: sheet.before_snapshot }
      end

      # GET /api/v1/skill_sheets/:id/comments
      def comments
        sheet = find_sheet or return
        render json: sheet.comments.map(&:as_payload)
      end

      # POST /api/v1/skill_sheets/:id/comments  { target?, body }
      def add_comment
        sheet = find_sheet or return
        comment = sheet.comments.create!(
          body: params.require(:body),
          target: params[:target],
          author_user_id: current_user.id,
          author_name: current_user.display_name
        )
        render json: comment.as_payload, status: :created
      rescue => e
        render_error(e.message)
      end

      # DELETE /api/v1/skill_sheets/:id/comments/:comment_id
      def destroy_comment
        sheet = find_sheet or return
        sheet.comments.find(params[:comment_id]).destroy!
        head :no_content
      end

      # PATCH /api/v1/skill_sheets/:id  アプリ内編集の保存
      def update
        sheet = find_sheet or return
        data = skill_sheet_params
        sheet.update!(data.except(:projects))
        sheet.apply_structured!(data) if data.key?(:projects)
        render json: sheet.reload.as_payload.merge(user: user_brief(sheet.user))
      rescue => e
        render_error(e.message)
      end

      # POST /api/v1/skill_sheets/:id/review  AI 添削 ({ instruction? })
      def review
        sheet = find_sheet or return
        result = SkillSheetReviewer.new(
          skill_sheet: sheet, user: current_user, instruction: params[:instruction]
        ).call
        render json: {
          review_result: result,
          reviewed_at: sheet.reviewed_at&.iso8601,
          review_items: sheet.review_items.reload.map(&:as_payload)
        }
      rescue => e
        render_error(e.message)
      end

      # GET /api/v1/skill_sheets/:id/review_items
      def review_items
        sheet = find_sheet or return
        render json: sheet.review_items.map(&:as_payload)
      end

      # POST /api/v1/skill_sheets/:id/review_items  手動で指摘を追加
      def create_review_item
        sheet = find_sheet or return
        item = sheet.review_items.create!(
          review_item_params.merge(source: "manual", position: sheet.review_items.maximum(:position).to_i + 1)
        )
        render json: item.as_payload
      rescue => e
        render_error(e.message)
      end

      # PATCH /api/v1/skill_sheets/:id/review_items/:item_id
      def update_review_item
        sheet = find_sheet or return
        item = sheet.review_items.find(params[:item_id])
        item.update!(review_item_params)
        render json: item.as_payload
      rescue => e
        render_error(e.message)
      end

      # DELETE /api/v1/skill_sheets/:id/review_items/:item_id
      def destroy_review_item
        sheet = find_sheet or return
        sheet.review_items.find(params[:item_id]).destroy!
        head :no_content
      end

      # POST /api/v1/skill_sheets/:id/generate  開発実績から AI 下書き生成 (保存はしない)
      def generate
        sheet = find_sheet or return
        draft = SkillSheetActivityComposer.new(user: sheet.user).call
        render json: { draft: draft }
      rescue => e
        render_error(e.message)
      end

      # POST /api/v1/skill_sheets/:id/analyze_tech  案件のフリーテキストから技術スタックを集計
      def analyze_tech
        sheet = find_sheet or return
        SkillSheetTechAnalyzer.new(skill_sheet: sheet, user: current_user).call
        render json: { techs: sheet.techs.reload.map(&:as_payload) }
      rescue => e
        render_error(e.message)
      end

      # POST /api/v1/skill_sheets/:id/suggest_techs  各案件のフリーテキストを AI でタグ化（保存しない・下書き返却）
      def suggest_techs
        sheet = find_sheet or return
        projects = SkillSheetProjectTechSuggester.new(skill_sheet: sheet, user: current_user).call
        render json: { projects: projects }
      rescue => e
        render_error(e.message)
      end

      # POST /api/v1/skill_sheets/:id/export  DB → スプレッドシート書き戻し + 整形
      # クリエイター(デザイン/動画編集)テンプレの人は専用エクスポータで「値だけ流し込む」。
      def export
        sheet = find_sheet or return
        exporter = sheet.template_type == "creator" ? CreatorSkillSheetExporter : SkillSheetExporter
        result = exporter.new(skill_sheet: sheet, user: current_user).call
        render json: result.merge(synced_at: sheet.reload.synced_at&.iso8601)
      rescue => e
        render_error(e.message)
      end

      # PATCH /api/v1/skill_sheets/:id/evaluations  { evaluations: [{label, level}, ...] }
      # スキル評価グリッド(A〜E)を一括 upsert。level が空/不正なら該当 label を削除。
      def set_evaluations
        sheet = find_sheet or return
        Array(params[:evaluations]).each do |entry|
          entry = entry.to_h.with_indifferent_access
          label = entry[:label].to_s.strip
          next if label.empty?
          level = entry[:level].to_s.strip.upcase
          record = sheet.evaluations.find_or_initialize_by(label: label)
          if SkillSheetEvaluation::LEVELS.include?(level)
            record.update!(level: level)
          elsif record.persisted?
            record.destroy!
          end
        end
        render json: { evaluations: sheet.evaluations.reload.map(&:as_payload) }
      rescue => e
        render_error(e.message)
      end

      # PATCH /api/v1/skill_sheets/:id/connection  外部連携トークンの保存（対象シートのユーザーに保持）
      def update_connection
        sheet = find_sheet or return
        attrs = {}
        attrs[:wantedly_token]    = params[:wantedly_token].to_s.presence    if params.key?(:wantedly_token)
        attrs[:anotherworks_token] = params[:anotherworks_token].to_s.presence if params.key?(:anotherworks_token)
        sheet.user.update!(attrs) if attrs.any?
        render json: { wantedly: sheet.user.wantedly_token.present?, anotherworks: sheet.user.anotherworks_token.present? }
      rescue => e
        render_error(e.message)
      end

      # POST /api/v1/skill_sheets/:id/sync_external
      # body: { platform: "wantedly"|"anotherworks"|"both"(default), project_position?: int }
      def sync_external
        sheet = find_sheet or return
        platforms = case params[:platform].to_s
        when "wantedly"     then [ :wantedly ]
        when "anotherworks" then [ :anotherworks ]
        else [ :wantedly, :anotherworks ]
        end
        only = params[:project_position].present? ? params[:project_position].to_i : nil
        result = JobProfileSyncer.new(skill_sheet: sheet, platforms: platforms, only_position: only).call
        render json: result.merge(projects: sheet.projects.reload.map(&:as_payload))
      rescue => e
        render_error(e.message)
      end

      # DELETE /api/v1/skill_sheets/:id
      def destroy
        sheet = find_sheet or return
        sheet.destroy!
        head :no_content
      end

      private

      def ensure_feature
        return if current_user.can_use?(:skill_sheet)
        render json: { error: "スキルシート機能の利用権限がありません" }, status: :forbidden
      end

      def find_sheet
        sheet = SkillSheet.find(params[:id])
        unless current_user.can_manage_user?(sheet.user_id)
          render json: { error: "このスキルシートを操作する権限がありません" }, status: :forbidden
          return nil
        end
        sheet
      end

      def resolve_target_user(user_id)
        target = user_id.present? ? User.find(user_id) : current_user
        unless current_user.can_manage_user?(target.id)
          render json: { error: "このユーザーのスキルシートを編集する権限がありません" }, status: :forbidden
          return nil
        end
        target
      end

      def user_brief(user)
        { id: user.id, display_name: user.display_name, email: user.email }
      end

      def skill_sheet_params
        params.require(:skill_sheet).permit(
          *SkillSheet::HEADER_ATTRS, :spreadsheet_url, :youtube_self_pr,
          projects: [
            :period_from, :period_to, :title, :description, :role_scale,
            :languages, :db, :server_os, :tools, :source,
            { phases: SkillSheetProject::PHASE_KEYS }
          ]
        )
      end

      def review_item_params
        params.require(:review_item).permit(:target, :field, :issues, :suggestion, :applied, :position)
      end

      def render_error(msg)
        render json: { error: msg }, status: :unprocessable_entity
      end
    end
  end
end
