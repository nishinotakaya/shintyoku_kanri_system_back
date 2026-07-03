module Api
  module V1
    # HeyGen による「本人が喋るインタビュー動画」生成。
    # YouTube マインドマップから台本を自動生成 → 写真/アバターで動画化 → テロップ編集 → プレビュー。
    class InterviewVideosController < BaseController
      before_action :ensure_feature

      # GET /api/v1/interview_videos?user_id=&interview_mindmap_id=
      def index
        scope = InterviewVideo.where(user_id: current_user.manageable_user_ids)
        scope = scope.where(user_id: params[:user_id]) if params[:user_id].present?
        scope = scope.where(interview_mindmap_id: params[:interview_mindmap_id]) if params[:interview_mindmap_id].present?
        videos = scope.order(created_at: :desc).to_a
        # 処理中の動画は HeyGen の最新状態を取り込む(リロード後も完成を拾えるように)
        videos.select { |v| v.status == "processing" && v.heygen_video_id.present? }.each { |v| sync_status!(v) }
        render json: videos.map(&:as_payload)
      end

      # GET /api/v1/interview_videos/:id  (生成中なら HeyGen の最新ステータスへ同期)
      def show
        v = find_video or return
        sync_status!(v) if v.status == "processing" && v.heygen_video_id.present?
        render json: v.as_payload
      end

      # POST /api/v1/interview_videos  下書き作成(台本・字幕は別途生成 or 手入力)
      def create
        target = resolve_target_user(params[:user_id]) or return
        v = InterviewVideo.new(
          user: target,
          interview_mindmap_id: params[:interview_mindmap_id],
          title: params[:title].presence || "インタビュー動画",
          script: params[:script].to_s,
          avatar_kind: params[:avatar_kind].presence || "avatar",
          avatar_id: params[:avatar_id],
          voice_id: params[:voice_id],
          status: "draft"
        )
        v.subtitle_list = params[:subtitles] if params[:subtitles].present?
        v.save!
        render json: v.as_payload, status: :created
      rescue => e
        render_error(e.message)
      end

      # PATCH /api/v1/interview_videos/:id  台本・テロップ・アバター/ボイスをシステムから編集
      def update
        v = find_video or return
        v.title = params[:title] if params.key?(:title)
        v.script = params[:script] if params.key?(:script)
        v.script_kana = params[:script_kana] if params.key?(:script_kana)
        v.avatar_kind = params[:avatar_kind] if params.key?(:avatar_kind)
        v.avatar_id = params[:avatar_id] if params.key?(:avatar_id)
        v.talking_photo_id = params[:talking_photo_id] if params.key?(:talking_photo_id)
        v.voice_id = params[:voice_id] if params.key?(:voice_id)
        v.subtitle_list = params[:subtitles] if params.key?(:subtitles)
        v.save!
        render json: v.as_payload
      rescue => e
        render_error(e.message)
      end

      def destroy
        v = find_video or return
        v.destroy!
        head :no_content
      end

      # GET /api/v1/interview_videos/options?user_id=  アバター/日本語ボイス/残高 + 自作アセット
      def options
        target = params[:user_id].present? ? User.find(params[:user_id]) : current_user
        client = HeygenClient.new(user: current_user)
        my_voices = target.heygen_assets.voices.order(created_at: :desc)
          .map { |a| { voice_id: a.ref_id, name: "🎙 #{a.name}", gender: "custom", custom: true } }
        my_avatars = target.heygen_assets.photo_avatars.order(created_at: :desc)
          .map { |a| { talking_photo_id: a.ref_id, name: "🧑 #{a.name}", preview: a.preview_url, custom: true } }
        render json: {
          remaining_quota: (client.remaining_quota rescue nil),
          avatars: client.avatars,
          voices: my_voices + client.japanese_voices,
          my_voices: my_voices,
          my_photo_avatars: my_avatars
        }
      rescue HeygenClient::Error => e
        render_error(e.message)
      end

      # POST /api/v1/interview_videos/:id/generate_script  台本を AI 生成
      def generate_script
        v = find_video or return
        generator = InterviewVideoScriptGenerator.new(user: current_user, persona_user: v.user, mindmap: v.interview_mindmap, topic: params[:topic], target_minutes: params[:target_minutes])
        script = generator.call
        v.update!(script: script, script_kana: nil) # 台本が変わったら読み仮名は作り直し
        render json: v.as_payload.merge(target_minutes: generator.target_minutes)
      rescue => e
        render_error(e.message)
      end

      # POST /api/v1/interview_videos/:id/generate_kana  台本→ひらがな読み(TTS誤読防止)
      def generate_kana
        v = find_video or return
        kana = InterviewVideoKanaGenerator.new(user: current_user, script: v.script, mode: params[:mode]).call
        v.update!(script_kana: kana)
        render json: v.as_payload
      rescue => e
        render_error(e.message)
      end

      # POST /api/v1/interview_videos/:id/proofread  台本をAI添削。矛盾は質問で返す。
      # answers(JSON)を渡すとそれを正として最終版を返す。
      def proofread
        v = find_video or return
        result = InterviewVideoProofreader.new(
          user: current_user, script: v.script, persona: v.user.video_script_context,
          title: v.title, answers: params[:answers]
        ).call
        # 確定回答ありで質問が無ければ本文も更新
        if params[:answers].present? && Array(result["questions"]).empty? && result["corrected_script"].present?
          v.update!(script: result["corrected_script"], script_kana: nil)
        end
        render json: result
      rescue => e
        render_error(e.message)
      end

      # POST /api/v1/interview_videos/:id/generate_subtitles  台本→テロップを AI 生成(強調つき)
      def generate_subtitles
        v = find_video or return
        segments = InterviewVideoSubtitleGenerator.new(user: current_user, script: v.script).call
        v.subtitle_list = segments
        v.save!
        render json: v.as_payload
      rescue => e
        render_error(e.message)
      end

      # POST /api/v1/interview_videos/:id/photo  写真アップロード→本人トーキングフォト化
      def upload_photo
        v = find_video or return
        file = params[:photo]
        return render_error("画像ファイルがありません") unless file.respond_to?(:read)
        client = HeygenClient.new(user: current_user)
        result = client.create_talking_photo(image_bytes: file.read, content_type: file.content_type || "image/jpeg")
        v.update!(avatar_kind: "talking_photo", talking_photo_id: result[:talking_photo_id], photo_url: result[:talking_photo_url])
        render json: v.as_payload
      rescue => e
        render_error(e.message)
      end

      # POST /api/v1/interview_videos/:id/render  HeyGen に生成依頼
      def render_video
        v = find_video or return
        return render_error("台本が空です") if v.script.to_s.strip.empty?
        return render_error("ボイスを選択してください") if v.voice_id.blank?
        client = HeygenClient.new(user: current_user)
        # 読み上げ前に必ず読みを最適化(誤読防止)。未生成なら自動で作る。
        if v.script_kana.blank? && v.script.present?
          auto = InterviewVideoKanaGenerator.new(user: current_user, script: v.script).call
          v.update!(script_kana: auto) if auto.present?
        end
        # 読み上げは読み最適化版を使う(字幕は漢字版のまま)。【見出し】等マーカーは喋らせない。
        spoken_text = strip_script_markers(v.script_kana.presence || v.script)
        heygen_id = client.generate_video(
          text: spoken_text,
          voice_id: v.voice_id,
          avatar_kind: v.avatar_kind,
          avatar_id: v.avatar_id,
          talking_photo_id: v.talking_photo_id
        )
        v.update!(heygen_video_id: heygen_id, status: "processing", video_url: nil, error: nil)
        render json: v.as_payload
      rescue => e
        render_error(e.message)
      end

      private

      def ensure_feature
        return if current_user.can_use?(:youtube_mindmap) || current_user.admin?
        render json: { error: "動画生成の利用権限がありません" }, status: :forbidden
      end

      def find_video
        v = InterviewVideo.find(params[:id])
        unless current_user.can_manage_user?(v.user_id)
          render json: { error: "この動画を操作する権限がありません" }, status: :forbidden
          return nil
        end
        v
      end

      def resolve_target_user(user_id)
        target = user_id.present? ? User.find(user_id) : current_user
        unless current_user.can_manage_user?(target.id)
          render json: { error: "このユーザーの動画を作成する権限がありません" }, status: :forbidden
          return nil
        end
        target
      end

      # HeyGen の最新ステータスを取り込み、完成していれば video_url とテロップ尺を確定
      def sync_status!(v)
        st = HeygenClient.new(user: current_user).video_status(v.heygen_video_id)
        case st[:status]
        when "completed"
          segments = InterviewVideoSubtitleGenerator.assign_timings(v.subtitle_list, st[:duration])
          v.subtitle_list = segments
          v.update!(status: "completed", video_url: st[:video_url], duration: st[:duration], error: nil)
        when "failed"
          v.update!(status: "failed", error: st[:error].to_s)
        end
      rescue HeygenClient::Error => e
        Rails.logger.warn("[InterviewVideo] status sync failed: #{e.message}")
      end

      def render_error(msg) = render(json: { error: msg }, status: :unprocessable_entity)

      # 台本の構造マーカー(【見出し】/ ■▶ / 行頭の「未来：」等ラベル)を除去して、
      # アバターに喋らせるテキストだけにする。見出しや項目名は読み上げない。
      LABELS = %w[挨拶 企画コール 大きな問題定義 具体例 最悪の未来 ベネフィット ターゲット指定 自己紹介
                  要点まとめ 本編 未来 問題 原因 解決 最終まとめ まとめ LINE誘導 アウトプット誘導].freeze
      def strip_script_markers(text)
        return text.to_s if text.to_s.strip.empty?
        label_re = /\A\s*(?:#{LABELS.join('|')}|要点内容[0-9０-９]*)\s*[:：]?\s*/
        lines = text.to_s.split("\n").map do |line|
          l = line.gsub(/【[^】]*】/, "").gsub(/[■◆●▶]/, "") # 見出し・箇条マーカー除去
          l = l.sub(label_re, "")                            # 行頭の構造ラベル除去
          l.strip
        end
        lines.join("\n").gsub(/\n{2,}/, "\n").strip # 空行は1つに圧縮
      end
    end
  end
end
