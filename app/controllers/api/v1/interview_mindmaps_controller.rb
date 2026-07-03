module Api
  module V1
    # 面談対策マインドマップ。admin は常に利用可 / feature_flags["interview_mindmap"] のユーザーも可。
    class InterviewMindmapsController < BaseController
      before_action :ensure_feature

      # GET /api/v1/interview_mindmaps?user_id=&mode=
      def index
        scope = InterviewMindmap.where(user_id: current_user.manageable_user_ids)
        scope = scope.where(user_id: params[:user_id]) if params[:user_id].present?
        mode = params[:mode].presence || "interview"
        scope = scope.where(mode: mode)
        # 権限が無いモードは空(管理者は素通り)
        return render(json: []) unless mode_allowed?(mode)
        render json: scope.order(updated_at: :desc).map { |m| m.as_payload.merge(user: user_brief(m.user)) }
      end

      # POST /api/v1/interview_mindmaps/suggest_titles  { user_id?, theme? }
      # onclass のリサーチ(高再生の傾向)＋対象者のスキルシートから YouTube タイトル案を生成。
      # マインドマップ作成前のタイトル入力補助に使う（YouTube 権限が必要）。
      def suggest_titles
        return render_forbidden("この機能の利用権限がありません") unless mode_allowed?("youtube")
        target = resolve_target_user(params[:user_id]) or return
        titles = YoutubeTitleSuggester.new(user: current_user, persona_user: target, theme: params[:theme]).call
        return render_error("タイトル案を生成できませんでした") if titles.blank?
        render json: { titles: titles }
      rescue => e
        render_error(e.message)
      end

      # GET /api/v1/interview_mindmaps/:id
      def show
        m = find_map or return
        render json: m.as_payload.merge(user: user_brief(m.user))
      end

      # POST /api/v1/interview_mindmaps  { user_id, title? }
      # 対象者のスキルシートを起点に root ノードを1つ作る。
      def create
        target = resolve_target_user(params[:user_id]) or return
        mode = params[:mode].presence || "interview"
        unless mode_allowed?(mode)
          return render_forbidden("この機能の利用権限がありません")
        end
        sheet = target.skill_sheet
        title = params[:title].presence || default_title_for(mode, target)
        map = InterviewMindmap.create!(user: target, skill_sheet: sheet, mode: mode, title: title)
        map.nodes.create!(kind: "root", text: root_text_for(mode, target, title), position: 0)
        render json: map.reload.as_payload.merge(user: user_brief(target)), status: :created
      rescue => e
        render_error(e.message)
      end

      # PATCH /api/v1/interview_mindmaps/:id  { title }
      # タイトル変更。YouTube は起点(root)テキストもタイトルに追従させる。
      def update
        m = find_map or return
        m.update!(title: params[:title]) if params[:title].present?
        m.nodes.find_by(kind: "root")&.update!(text: m.title) if m.youtube?
        render json: m.reload.as_payload.merge(user: user_brief(m.user))
      rescue => e
        render_error(e.message)
      end

      # POST /api/v1/interview_mindmaps/:id/nodes/:node_id/expand
      # AI で子ノードを生成して DB 保存し、生成分を返す。
      def expand_node
        m = find_map or return
        node = m.nodes.find(params[:node_id])
        children_spec = InterviewNodeExpander.new(mindmap: m, node: node, user: current_user).call
        created = []
        InterviewMindmap.transaction do
          children_spec.each_with_index do |c, idx|
            created << m.nodes.create!(parent_id: node.id, kind: c[:kind], text: c[:text], position: idx)
          end
          node.update!(expanded: true)
        end
        render json: { children: created.map(&:as_payload) }
      rescue => e
        render_error(e.message)
      end

      # POST /api/v1/interview_mindmaps/:id/nodes/:node_id/proofread
      # ノードのテキストを AI 添削（人が話すように自然な文章へまとめる）。
      # 保存はせず添削結果だけ返し、フロントで本人がレビューしてから保存する（非破壊）。
      def proofread_node
        m = find_map or return
        node = m.nodes.find(params[:node_id])
        return render_error("添削するテキストがありません") if node.text.to_s.strip.empty?
        corrected = InterviewNodeProofreader.new(mindmap: m, node: node, user: current_user).call
        return render_error("添削結果を取得できませんでした") if corrected.blank?
        render json: { corrected_text: corrected }
      rescue => e
        render_error(e.message)
      end

      # POST /api/v1/interview_mindmaps/:id/import_bank
      # 質問バンク(スプレッドシート)から質問を絞って取り込み、各質問に模範回答/深掘り/言い方を子ノードで付ける。
      def import_bank
        m = find_map or return
        root = m.nodes.find_by(kind: "root") || m.nodes.order(:position).first
        return render_error("起点ノードがありません") unless root
        return import_youtube_bank(m, root) if m.youtube?
        return import_mote_bank(m, root) if m.mote?
        bank = InterviewBankImporter.new(user: current_user).call
        InterviewMindmap.transaction do
          base = root.children.maximum(:position).to_i + 1
          bank.each_with_index do |row, i|
            q = m.nodes.create!(parent_id: root.id, kind: "question", text: row[:question], position: base + i, expanded: true, source: "bank")
            m.nodes.create!(parent_id: q.id, kind: "answer",  text: row[:answer],  position: 0, source: "bank") if row[:answer].present?
            m.nodes.create!(parent_id: q.id, kind: "followup", text: row[:followup], position: 1, source: "bank") if row[:followup].present?
          end
          root.update!(expanded: true)
        end
        render json: m.reload.as_payload.merge(imported: bank.size)
      rescue => e
        render_error(e.message)
      end

      # POST /api/v1/interview_mindmaps/:id/export_sheet  { spreadsheet_url }
      # マインドマップを Google スプレッドシートへ書き出す（URLは保存）。
      def export_sheet
        m = find_map or return
        url = params[:spreadsheet_url].to_s.strip
        return render_error("スプレッドシートの URL を入力してください") if url.empty?
        m.update!(spreadsheet_url: url)
        result = InterviewMindmapSheetExporter.new(mindmap: m, user: current_user, spreadsheet_url: url).call
        render json: result.merge(spreadsheet_url: url)
      rescue => e
        render_error(e.message)
      end

      # POST /api/v1/interview_mindmaps/:id/reset  起点(root)以外の全ノードを削除
      def reset
        m = find_map or return
        root = m.nodes.find_by(kind: "root")
        m.nodes.where.not(id: root&.id).destroy_all
        root&.update(expanded: false)
        render json: m.reload.as_payload
      rescue => e
        render_error(e.message)
      end

      # YouTube: 固定の質問バンク(12問)を root 配下に並べる(回答は各質問の展開時に生成)
      def import_youtube_bank(m, root)
        InterviewMindmap.transaction do
          base = root.children.maximum(:position).to_i + 1
          InterviewMindmap::YOUTUBE_QUESTIONS.each_with_index do |q, i|
            m.nodes.create!(parent_id: root.id, kind: "question", text: q, position: base + i, source: "bank")
          end
          root.update!(expanded: true)
        end
        render json: m.reload.as_payload.merge(imported: InterviewMindmap::YOUTUBE_QUESTIONS.size)
      rescue => e
        render_error(e.message)
      end

      # モテ: 相手のセリフ(質問=Q) → 自分のモテ返し(回答=A) を会話形式で root 配下に並べる
      def import_mote_bank(m, root)
        InterviewMindmap.transaction do
          base = root.children.maximum(:position).to_i + 1
          InterviewMindmap::MOTE_DIALOGUES.each_with_index do |d, i|
            q = m.nodes.create!(parent_id: root.id, kind: "question", text: d[:q], position: base + i, source: "bank", expanded: true)
            m.nodes.create!(parent_id: q.id, kind: "answer", text: d[:a], position: 0, source: "bank")
          end
          root.update!(expanded: true)
        end
        total = InterviewMindmap::MOTE_DIALOGUES.size
        render json: m.reload.as_payload.merge(imported: total)
      rescue => e
        render_error(e.message)
      end

      # POST /api/v1/interview_mindmaps/:id/nodes/:node_id/speech
      # ノードのテキストを OpenAI TTS で読み上げた音声(mp3)を返す。YouTube用の高品質音声。
      def speech
        m = find_map or return
        node = m.nodes.find(params[:node_id])
        audio = OpenaiTts.new(user: current_user).synthesize(node.text)
        send_data audio, type: "audio/mpeg", disposition: "inline"
      rescue => e
        render_error(e.message)
      end

      # POST /api/v1/interview_mindmaps/:id/reset_bank  質問バンク取り込み分(source=bank)だけ削除
      def reset_bank
        m = find_map or return
        removed = m.nodes.where(source: "bank").destroy_all.size
        render json: m.reload.as_payload.merge(removed: removed)
      rescue => e
        render_error(e.message)
      end

      # POST /api/v1/interview_mindmaps/:id/nodes  { parent_id?, kind?, text? }
      # 手動でノード(既定: 空のQ)を追加する。
      def create_node
        m = find_map or return
        parent = params[:parent_id].present? ? m.nodes.find(params[:parent_id]) : m.nodes.find_by(kind: "root")
        pos = (parent ? parent.children.maximum(:position) : m.nodes.where(parent_id: nil).maximum(:position)).to_i + 1
        node = m.nodes.create!(
          parent_id: parent&.id,
          kind: (params[:kind].presence || "question"),
          text: params[:text].to_s,
          position: pos
        )
        render json: node.as_payload, status: :created
      rescue => e
        render_error(e.message)
      end

      # PATCH /api/v1/interview_mindmaps/:id/nodes/:node_id  { text?, checked? }
      def update_node
        m = find_map or return
        node = m.nodes.find(params[:node_id])
        attrs = {}
        attrs[:text] = params[:text].to_s if params.key?(:text)
        attrs[:checked] = ActiveModel::Type::Boolean.new.cast(params[:checked]) if params.key?(:checked)
        node.update!(attrs) if attrs.any?
        render json: node.as_payload
      rescue => e
        render_error(e.message)
      end

      # DELETE /api/v1/interview_mindmaps/:id/nodes/:node_id  (サブツリーごと)
      def destroy_node
        m = find_map or return
        m.nodes.find(params[:node_id]).destroy!
        head :no_content
      end

      # PATCH /api/v1/interview_mindmaps/:id/nodes/:node_id/hover  { hovering: true/false }
      # 共有ホバー: 自分がそのノードにカーソルを当てた/離した を記録(非同期)
      def hover_node
        m = find_map or return
        node = m.nodes.find(params[:node_id])
        if ActiveModel::Type::Boolean.new.cast(params[:hovering])
          node.update_columns(hovered_by_user_id: current_user.id, hovered_at: Time.current)
        elsif node.hovered_by_user_id == current_user.id
          node.update_columns(hovered_by_user_id: nil, hovered_at: nil)
        end
        head :no_content
      rescue => e
        render_error(e.message)
      end

      # GET /api/v1/interview_mindmaps/:id/hovers  軽量: 新鮮な他者ホバーだけ返す
      def hovers
        m = find_map or return
        fresh = m.nodes.where.not(hovered_by_user_id: nil).where("hovered_at >= ?", HOVER_TTL.seconds.ago)
        render json: fresh.map { |n| { node_id: n.id, user_id: n.hovered_by_user_id } }
      end

      # DELETE /api/v1/interview_mindmaps/:id
      def destroy
        m = find_map or return
        m.destroy!
        head :no_content
      end

      private

      HOVER_TTL = 10 # 秒。これより古いホバーは無視(mouseleave取りこぼし対策)

      def ensure_feature
        return if current_user.can_use?(:interview_mindmap) || current_user.can_use?(:youtube_mindmap)
        render json: { error: "面談対策マインドマップの利用権限がありません" }, status: :forbidden
      end

      def find_map
        m = InterviewMindmap.find(params[:id])
        unless current_user.can_manage_user?(m.user_id)
          render json: { error: "このマインドマップを操作する権限がありません" }, status: :forbidden
          return nil
        end
        unless mode_allowed?(m.mode)
          render json: { error: "この機能の利用権限がありません" }, status: :forbidden
          return nil
        end
        m
      end

      # interview は誰でも(ensure_feature 済み)、youtube/mote は専用フラグ(admin素通り)が要る
      def mode_allowed?(mode)
        return true unless %w[youtube mote].include?(mode)
        current_user.can_use?(:"#{mode}_mindmap")
      end

      def default_title_for(mode, target)
        case mode
        when "youtube" then "#{target.display_name} YouTube用"
        when "mote"    then "#{target.display_name} モテ会話"
        else "#{target.display_name} 面談対策"
        end
      end

      def root_text_for(mode, target, title)
        case mode
        when "youtube" then title # 動画タイトル/テーマを起点に表示
        when "mote"    then "モテコミュニケーション"
        else "#{target.display_name} のスキルシート"
        end
      end

      def render_forbidden(msg) = render(json: { error: msg }, status: :forbidden)

      def resolve_target_user(user_id)
        target = user_id.present? ? User.find(user_id) : current_user
        unless current_user.can_manage_user?(target.id)
          render json: { error: "このユーザーのマインドマップを作成する権限がありません" }, status: :forbidden
          return nil
        end
        target
      end

      def user_brief(user) = { id: user.id, display_name: user.display_name, email: user.email }

      def render_error(msg) = render(json: { error: msg }, status: :unprocessable_entity)
    end
  end
end
