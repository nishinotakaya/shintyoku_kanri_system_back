module Api
  module V1
    # YouTube サムネ生成。
    # フロー: copy(文言生成) → background(gpt-image-1で背景) → フロントCanvasで文字合成
    #         → create(完成PNG保存)。または to_canva(Canvaで仕上げ) → import_canva(書き出して保存)。
    class ThumbnailsController < BaseController
      before_action :set_thumbnail, only: %i[show destroy clean_background]

      # GET /api/v1/thumbnails/defaults
      # フロントのプロンプト編集欄/文字スタイルの初期値。
      def defaults
        render json: {
          background_template: ThumbnailPrompts.background_template,
          styles: ThumbnailPrompts.styles,
          default_style: ThumbnailPrompts::DEFAULT_STYLE,
          text_style: ThumbnailPrompts::DEFAULT_TEXT_STYLE,
          canva: { configured: CanvaClient.configured?, connected: current_user.canva_refresh_token.present? }
        }
      end

      # GET /api/v1/thumbnails?mindmap_id=
      def index
        scope = GeneratedThumbnail.where(user_id: current_user.manageable_user_ids).recent.limit(100)
        scope = scope.where(interview_mindmap_id: params[:mindmap_id]) if params[:mindmap_id].present?
        render json: scope.map(&:as_payload)
      end

      # POST /api/v1/thumbnails/copy  { mindmap_id? , title?, summary? }
      # タイトル+要点からコピー(文言)を生成し、背景プロンプトのたたき台も返す。
      def copy
        title, summary = title_and_summary
        return render_error("タイトルが必要です") if title.blank?

        # current(下書き)が来たら添削モード。proofread=true なら「誤字脱字のみ」、それ以外は従来の改善。
        current = params[:current].respond_to?(:to_unsafe_h) ? params[:current].to_unsafe_h : params[:current]
        proofread = ActiveModel::Type::Boolean.new.cast(params[:proofread])
        copy = ThumbnailCopywriter.new(user: current_user).call(title: title, summary: summary, current: current, proofread: proofread)
        render json: {
          copy: copy,
          background_prompt: ThumbnailPrompts.background_prompt(title: title, summary: summary, style: style_param)
        }
      rescue => e
        render_error(e.message)
      end

      # POST /api/v1/thumbnails/background  { prompt }
      # 背景PNGを生成して data URL で返す(まだ保存しない。フロントCanvasで文字合成に使う)。
      def background
        prompt = params[:prompt].to_s
        prompt = ThumbnailPrompts.background_prompt(title: title_and_summary.first, summary: title_and_summary.last, style: style_param) if prompt.blank?
        bytes = ThumbnailBackgroundGenerator.new(user: current_user).call(prompt: prompt)
        render json: { image_base64: "data:image/png;base64,#{Base64.strict_encode64(bytes)}", prompt: prompt }
      rescue => e
        render_error(e.message)
      end

      # POST /api/v1/thumbnails
      # フロントCanvasで合成した完成PNG(data URL)を保存する。
      # { mindmap_id?, title, prompt?, copy?(obj), image_base64, source? }
      def create
        bytes = decode_data_url(params[:image_base64])
        return render_error("画像データが必要です") if bytes.blank?

        thumb = GeneratedThumbnail.new(
          user: current_user,
          interview_mindmap_id: params[:mindmap_id].presence,
          title: params[:title].to_s,
          prompt: params[:prompt].to_s,
          source: params[:source].presence_in(GeneratedThumbnail::SOURCES) || "gpt_image",
          content_type: "image/png",
          byte_size: bytes.bytesize,
          data: bytes
        )
        thumb.copy = params[:copy].respond_to?(:to_unsafe_h) ? params[:copy].to_unsafe_h : params[:copy]
        # 再編集用の「文字なし背景」も保存（あれば）。これがあれば編集時に文字が二重にならない。
        clean = decode_data_url(params[:clean_background_base64])
        thumb.clean_background = clean if clean.present?
        thumb.save!
        render json: thumb.as_payload, status: :created
      rescue => e
        render_error(e.message)
      end

      # GET /api/v1/thumbnails/:id/image  (バイナリ配信)
      def show
        send_data @thumbnail.data, type: @thumbnail.content_type, disposition: "inline",
                  filename: "thumbnail_#{@thumbnail.id}.png"
      end

      # GET /api/v1/thumbnails/:id/clean_background  (文字なし背景の配信。再編集の下敷き用)
      def clean_background
        return head :not_found if @thumbnail.clean_background.blank?

        send_data @thumbnail.clean_background, type: "image/png", disposition: "inline",
                  filename: "thumbnail_#{@thumbnail.id}_bg.png"
      end

      # DELETE /api/v1/thumbnails/:id
      def destroy
        @thumbnail.destroy!
        render json: { ok: true }
      end

      # POST /api/v1/thumbnails/to_canva  { prompt? , image_base64? , title? }
      # 背景をCanvaにアップロード→デザイン作成→編集URLを返す(Canvaで文字を仕上げる)。
      def to_canva
        return render_error("Canva に接続されていません") unless current_user.canva_refresh_token.present?

        client = CanvaClient.new(current_user)
        title = params[:title].presence || "YouTubeサムネ"
        texts = params[:texts].respond_to?(:to_unsafe_h) ? params[:texts].to_unsafe_h : {}
        template_id = ENV["CANVA_BRAND_TEMPLATE_ID"].presence
        use_autofill = template_id.present? && texts.values.any? { |v| v.to_s.strip.present? } && params[:background_base64].present?

        if use_autofill
          # テンプレあり: 背景は文字なしのクリーン画像、文言は編集可能テキストとして Autofill
          bytes = decode_data_url(params[:background_base64])
          asset_id = client.upload_asset(bytes, name: "#{title}_背景.png")
          result = client.autofill(template_id, title: title, image_asset_id: asset_id, texts: texts)
        else
          # テンプレ無し: 文字込みの合成画像をそのまま送る（文言がCanvaにも見えるように）。
          bytes =
            if params[:image_base64].present?
              decode_data_url(params[:image_base64])
            elsif params[:background_base64].present?
              decode_data_url(params[:background_base64])
            else
              ThumbnailBackgroundGenerator.new(user: current_user).call(prompt: params[:prompt].to_s.presence || ThumbnailPrompts.background_prompt(title: title_and_summary.first, summary: title_and_summary.last))
            end
          asset_id = client.upload_asset(bytes, name: "#{title}.png")
          result = client.create_design_from_asset(asset_id, title: title)
        end

        thumb = GeneratedThumbnail.create!(
          user: current_user,
          interview_mindmap_id: params[:mindmap_id].presence,
          title: title,
          prompt: params[:prompt].to_s,
          source: "canva",
          canva_design_id: result[:design_id],
          canva_edit_url: result[:edit_url],
          content_type: "image/png",
          byte_size: bytes.bytesize,
          data: bytes # 暫定で背景を保存。仕上げ後 import_canva で差し替え
        )
        render json: thumb.as_payload.merge(edit_url: result[:edit_url])
      rescue => e
        render_error(e.message)
      end

      # POST /api/v1/thumbnails/:id/import_canva
      # Canvaで仕上げたデザインを PNG 書き出しして保存データを差し替える。
      def import_canva
        thumb = GeneratedThumbnail.where(user_id: current_user.manageable_user_ids).find(params[:id])
        return render_error("Canvaデザインが紐づいていません") if thumb.canva_design_id.blank?

        url = CanvaClient.new(current_user).export_png(thumb.canva_design_id)
        bytes = URI.open(url, &:read) # rubocop:disable Security/Open
        thumb.update!(data: bytes, byte_size: bytes.bytesize)
        render json: thumb.as_payload
      rescue => e
        render_error(e.message)
      end

      private

      def set_thumbnail
        @thumbnail = GeneratedThumbnail.where(user_id: current_user.manageable_user_ids).find(params[:id])
      end

      # mindmap_id があればそのタイトル+上位ノードから要点を作る。なければ params。
      def title_and_summary
        if params[:mindmap_id].present?
          map = InterviewMindmap.where(user_id: current_user.manageable_user_ids).find_by(id: params[:mindmap_id])
          if map
            points = map.nodes
                        .select { |n| %w[question keyword answer].include?(n.kind) }
                        .first(6).map(&:text).join(" / ")
            return [ params[:title].presence || map.title, params[:summary].presence || points ]
          end
        end
        [ params[:title].to_s, params[:summary].to_s ]
      end

      def style_param
        params[:style].presence || ThumbnailPrompts::DEFAULT_STYLE
      end

      def decode_data_url(str)
        s = str.to_s
        s = s.split(",", 2).last if s.start_with?("data:")
        Base64.decode64(s)
      rescue StandardError
        nil
      end

      def render_error(message, status: :unprocessable_entity)
        render json: { error: message }, status: status
      end
    end
  end
end
