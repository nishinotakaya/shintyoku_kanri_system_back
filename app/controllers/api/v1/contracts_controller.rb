module Api
  module V1
    # 業務委託契約書。発行者(甲=current_user)側の CRUD と、署名リンク発行・複製・無効化・PDF。
    class ContractsController < BaseController
      before_action do
        render(json: { error: "契約書機能の権限がありません" }, status: :forbidden) unless current_user.can_use?(:contracts)
      end
      before_action :set_contract, only: %i[show update destroy issue duplicate void pdf]

      # GET /api/v1/contracts
      def index
        contracts = scope.order(updated_at: :desc)
        render json: contracts.map { |contract| contract_json(contract) }
      end

      # GET /api/v1/contracts/:id
      def show
        render json: contract_json(@contract)
      end

      # POST /api/v1/contracts
      def create
        attrs = contract_params
        attrs[:title] = attrs[:title].presence || "業務委託契約書"
        # template 未指定なら従来どおり標準の15条。transport を指定すると運送業務委託契約書(29条)になる。
        attrs[:articles] = attrs[:articles].presence || Contract.articles_for_template(params[:template])
        apply_default_party_a!(attrs) if attrs[:party_a_name].blank?

        contract = current_user.contracts.create!(attrs)
        contract.record_event("created", actor: actor_label, ip: request.remote_ip, user_agent: request.user_agent)
        render json: contract_json(contract), status: :created
      end

      # PATCH /api/v1/contracts/:id
      def update
        unless @contract.editable?
          return render(json: { error: "署名済みの契約書は変更できません" }, status: :unprocessable_entity)
        end

        @contract.update!(contract_params)
        @contract.record_event("updated", actor: actor_label, ip: request.remote_ip, user_agent: request.user_agent)
        render json: contract_json(@contract)
      end

      # DELETE /api/v1/contracts/:id
      def destroy
        unless @contract.status == "draft"
          return render(json: { error: "下書きの契約書のみ削除できます" }, status: :unprocessable_entity)
        end

        @contract.destroy!
        head :no_content
      end

      # POST /api/v1/contracts/:id/issue
      def issue
        unless @contract.editable?
          return render(json: { error: "この契約書は発行できません" }, status: :unprocessable_entity)
        end

        raw_token = @contract.issue!(actor: actor_label)
        share_url = "#{ENV.fetch('FRONTEND_BASE_URL', 'https://react-frontend-beige.vercel.app')}/sign/contracts/#{raw_token}"
        render json: contract_json(@contract, share_url: share_url)
      end

      # POST /api/v1/contracts/:id/duplicate
      def duplicate
        new_contract = @contract.duplicate_for(current_user)
        new_contract.record_event("duplicated", actor: actor_label, detail: { source_contract_id: @contract.id })
        render json: contract_json(new_contract), status: :created
      end

      # POST /api/v1/contracts/:id/void
      def void
        unless @contract.status == "sent"
          return render(json: { error: "送付済みの契約書のみ無効にできます" }, status: :unprocessable_entity)
        end

        @contract.update!(status: "void")
        @contract.record_event("voided", actor: actor_label, ip: request.remote_ip, user_agent: request.user_agent)
        render json: contract_json(@contract)
      end

      # GET /api/v1/contracts/:id/pdf
      def pdf
        if @contract.status == "signed" && @contract.signed_pdf.present?
          send_data @contract.signed_pdf, type: "application/pdf", filename: pdf_filename(@contract), disposition: "inline"
        else
          send_data ContractPdfRenderer.new(@contract).render_bytes, type: "application/pdf", filename: pdf_filename(@contract), disposition: "inline"
        end
      end

      private

      # IDOR 防止: admin は全件、それ以外は自分の契約書のみ。
      def scope
        current_user.admin? ? Contract.all : current_user.contracts
      end

      def set_contract
        @contract = scope.find(params[:id])
      end

      def actor_label
        "user:#{current_user.id}"
      end

      def contract_params
        params.fetch(:contract, {}).permit(
          :title, :party_a_name, :party_a_address, :party_a_representative,
          :party_b_name, :party_b_address, :party_b_representative,
          :contract_date, :start_on, :end_on, :special_terms,
          articles: [ :heading, :body, :page_break_before ]
        ).to_h.symbolize_keys
      end

      # party_a が未指定なら、同ユーザーの直近契約書の甲情報を引き継ぐ。無ければ display_name のみ。
      def apply_default_party_a!(attrs)
        previous = current_user.contracts.order(created_at: :desc).first
        if previous
          attrs[:party_a_name] = previous.party_a_name
          attrs[:party_a_address] ||= previous.party_a_address
          attrs[:party_a_representative] ||= previous.party_a_representative
        else
          attrs[:party_a_name] = current_user.display_name.to_s
        end
      end

      def pdf_filename(contract)
        "#{contract.title}_#{contract.id}.pdf"
      end

      def contract_json(contract, share_url: nil)
        json = {
          id: contract.id,
          title: contract.title,
          status: contract.status,
          party_a: contract.party_a_hash,
          party_b: contract.party_b_hash,
          contract_date: contract.contract_date&.iso8601,
          start_on: contract.start_on&.iso8601,
          end_on: contract.end_on&.iso8601,
          articles: normalized_articles(contract.articles),
          special_terms: contract.special_terms.to_s,
          share_expires_at: contract.share_expires_at&.iso8601,
          sent_at: contract.sent_at&.iso8601,
          signed_at: contract.signed_at&.iso8601,
          signer_name: contract.signer_name,
          content_sha256: contract.content_sha256,
          has_signed_pdf: contract.signed_pdf.present?,
          editable: contract.editable?,
          user_name: contract.user.display_name,
          created_at: contract.created_at.iso8601,
          updated_at: contract.updated_at.iso8601
        }
        json[:share_url] = share_url if share_url.present?
        json
      end

      # 画面に返す条文。page_break_before は「この条文の前で改ページする」フラグ(紙の原本の再現用)。
      def normalized_articles(articles)
        Array(articles).map do |article|
          indifferent = article.is_a?(Hash) ? article.with_indifferent_access : {}
          {
            heading: indifferent[:heading].to_s,
            body: indifferent[:body].to_s,
            page_break_before: ActiveModel::Type::Boolean.new.cast(indifferent[:page_break_before]) || false
          }
        end
      end
    end
  end
end
