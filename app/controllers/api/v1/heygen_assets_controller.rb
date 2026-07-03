module Api
  module V1
    # 勤怠アプリ内で作る「自分の声(クローン)」「自分の顔(トーキングフォト)」を管理する。
    # 録音/写真はフロントで取得し、ここで HeyGen に渡して voice_id / talking_photo_id を得て保存する。
    class HeygenAssetsController < BaseController
      before_action :ensure_feature

      # GET /api/v1/heygen_assets?user_id=
      def index
        target = resolve_target_user(params[:user_id]) or return
        render json: target.heygen_assets.order(created_at: :desc).map(&:as_payload)
      end

      # POST /api/v1/heygen_assets/clone_voice  (multipart: audio, name?, user_id?)
      def clone_voice
        target = resolve_target_user(params[:user_id]) or return
        file = params[:audio]
        return render_error("音声ファイルがありません") unless file.respond_to?(:read)
        name = params[:name].presence || "#{target.display_name}の声 #{Time.current.strftime('%m/%d %H:%M')}"
        client = HeygenClient.new(user: current_user)
        voice_id = client.clone_voice(audio_bytes: file.read, name: name, content_type: file.content_type || "audio/wav")
        asset = target.heygen_assets.create!(kind: "voice", ref_id: voice_id, name: name, status: "ready")
        render json: asset.as_payload, status: :created
      rescue => e
        render_error(e.message)
      end

      # POST /api/v1/heygen_assets/create_avatar  (multipart: photo, name?, user_id?)
      def create_avatar
        target = resolve_target_user(params[:user_id]) or return
        file = params[:photo]
        return render_error("画像ファイルがありません") unless file.respond_to?(:read)
        name = params[:name].presence || "#{target.display_name}の顔 #{Time.current.strftime('%m/%d %H:%M')}"
        client = HeygenClient.new(user: current_user)
        result = client.create_talking_photo(image_bytes: file.read, content_type: file.content_type || "image/jpeg")
        asset = target.heygen_assets.create!(kind: "photo_avatar", ref_id: result[:talking_photo_id], name: name, status: "ready", preview_url: result[:talking_photo_url])
        render json: asset.as_payload, status: :created
      rescue => e
        render_error(e.message)
      end

      # POST /api/v1/heygen_assets/test_video  (voice_id, talking_photo_id, text?, user_id?)
      # スタジオ内で「この声・顔」の短いテスト動画を作る。InterviewVideo を作って render し、
      # フロントは GET /interview_videos/:id でポーリングしてプレビューする。
      def test_video
        target = resolve_target_user(params[:user_id]) or return
        return render_error("声を選んでください") if params[:voice_id].blank?
        text = params[:text].presence || "これは私の声と顔のテストです。きちんと本人の声と顔で喋れているか確認します。"
        v = target.interview_videos.create!(
          title: "声・顔テスト", script: text, status: "draft",
          voice_id: params[:voice_id],
          avatar_kind: params[:talking_photo_id].present? ? "talking_photo" : "avatar",
          talking_photo_id: params[:talking_photo_id], avatar_id: params[:avatar_id]
        )
        heygen_id = HeygenClient.new(user: current_user).generate_video(
          text: text, voice_id: v.voice_id, avatar_kind: v.avatar_kind,
          avatar_id: v.avatar_id, talking_photo_id: v.talking_photo_id
        )
        v.update!(heygen_video_id: heygen_id, status: "processing")
        render json: v.as_payload, status: :created
      rescue => e
        render_error(e.message)
      end

      # DELETE /api/v1/heygen_assets/:id
      def destroy
        asset = HeygenAsset.find(params[:id])
        return render_forbidden("権限がありません") unless current_user.can_manage_user?(asset.user_id)
        HeygenClient.new(user: current_user).delete_voice(asset.ref_id) if asset.kind == "voice"
        asset.destroy!
        head :no_content
      rescue => e
        render_error(e.message)
      end

      private

      def ensure_feature
        return if current_user.can_use?(:youtube_mindmap) || current_user.admin?
        render json: { error: "この機能の利用権限がありません" }, status: :forbidden
      end

      def resolve_target_user(user_id)
        target = user_id.present? ? User.find(user_id) : current_user
        unless current_user.can_manage_user?(target.id)
          render json: { error: "このユーザーの操作権限がありません" }, status: :forbidden
          return nil
        end
        target
      end

      def render_forbidden(msg) = render(json: { error: msg }, status: :forbidden)
      def render_error(msg) = render(json: { error: msg }, status: :unprocessable_entity)
    end
  end
end
