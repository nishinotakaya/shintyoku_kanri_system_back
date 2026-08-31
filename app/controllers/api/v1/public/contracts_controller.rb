module Api
  module V1
    module Public
      # 契約書の相手方(乙)向け公開エンドポイント。ログイン不要。
      # トークン保持者=乙本人という推定のみで、OTP等の本人確認は行わない(既知の制約)。
      class ContractsController < BaseController
        skip_before_action :authenticate_user!

        before_action :set_no_index_headers
        before_action :set_contract

        # GET /api/v1/public/contracts/:token
        def show
          @contract.record_event("viewed", actor: "party_b", ip: request.remote_ip, user_agent: request.user_agent)
          render json: {
            title: @contract.title,
            party_a: @contract.party_a_hash,
            party_b: @contract.party_b_hash,
            contract_date: @contract.contract_date&.iso8601,
            start_on: @contract.start_on&.iso8601,
            end_on: @contract.end_on&.iso8601,
            articles: normalized_articles(@contract.articles),
            special_terms: @contract.special_terms.to_s,
            status: @contract.status,
            signed_at: @contract.signed_at&.iso8601,
            signer_name: @contract.signer_name,
            signable: @contract.signable?,
            expired: @contract.share_expires_at.present? && @contract.share_expires_at.past?
          }
        end

        # GET /api/v1/public/contracts/:token/pdf
        def pdf
          @contract.record_event("pdf_viewed", actor: "party_b", ip: request.remote_ip, user_agent: request.user_agent)
          if @contract.status == "signed" && @contract.signed_pdf.present?
            send_data @contract.signed_pdf, type: "application/pdf", filename: pdf_filename, disposition: "inline"
          else
            send_data ContractPdfRenderer.new(@contract).render_bytes, type: "application/pdf", filename: pdf_filename, disposition: "inline"
          end
        end

        # POST /api/v1/public/contracts/:token/sign
        def sign
          unless truthy?(params[:agreed]) && truthy?(params[:consent_electronic])
            return render(json: { error: "契約内容への同意と電磁的方法での受け取りへの同意の両方が必要です" }, status: :unprocessable_entity)
          end

          @contract.sign!(
            signer_name: params[:signer_name].to_s,
            signature_image: params[:signature_image].to_s,
            ip: request.remote_ip,
            user_agent: request.user_agent
          )
          render json: { status: "signed", signed_at: @contract.signed_at.iso8601 }
        rescue Contract::NotSignable
          render json: { error: "この契約書は署名できません（期限切れ・既に署名済み・無効）" }, status: :conflict
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: e.record.errors.full_messages.join("、") }, status: :unprocessable_entity
        end

        private

        def set_no_index_headers
          response.headers["Cache-Control"] = "no-store"
          response.headers["X-Robots-Tag"] = "noindex, nofollow"
        end

        # トークン不一致は 404。トークン自体はログに出さない(filter_parameter_logging の :token)。
        def set_contract
          @contract = Contract.find_by_share_token(params[:token])
          render(json: { error: "契約書が見つかりません" }, status: :not_found) unless @contract
        end

        def truthy?(value)
          ActiveModel::Type::Boolean.new.cast(value)
        end

        def pdf_filename
          "#{@contract.title}_#{@contract.id}.pdf"
        end

        def normalized_articles(articles)
          Array(articles).map do |article|
            indifferent = article.is_a?(Hash) ? article.with_indifferent_access : {}
            { heading: indifferent[:heading].to_s, body: indifferent[:body].to_s }
          end
        end
      end
    end
  end
end
