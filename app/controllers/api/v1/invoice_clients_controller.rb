module Api
  module V1
    # 請求先(宛先)マスタの CRUD。
    # as_user_id を付ければ admin は対象ユーザーの請求先を扱える(viewing_user)。
    # 自分(または admin が見ているユーザー)の請求先しか触れない。
    class InvoiceClientsController < BaseController
      before_action :set_client, only: [ :update, :destroy ]

      def index
        render json: viewing_user.invoice_clients.active.ordered.map { |client| serialize(client) }
      end

      def create
        client = viewing_user.invoice_clients.new(client_params)
        client.save!
        render json: serialize(client), status: :created
      end

      def update
        @client.update!(client_params)
        render json: serialize(@client)
      end

      # 物理削除しない(過去の請求書が参照する)。一覧から消えるだけ。
      def destroy
        @client.archive!
        head :no_content
      end

      private

      def set_client
        @client = viewing_user.invoice_clients.find_by(id: params[:id])
        render(json: { error: "請求先が見つかりません" }, status: :not_found) if @client.nil?
      end

      def client_params
        params.require(:invoice_client).permit(
          :name, :honorific, :subject, :postal_code, :address, :tel, :fax,
          :contact_name, :note, :is_default, :position
        )
      end

      def serialize(client)
        {
          id: client.id, name: client.name, honorific: client.display_honorific,
          subject: client.subject, postal_code: client.postal_code, address: client.address,
          tel: client.tel, fax: client.fax, contact_name: client.contact_name,
          note: client.note, is_default: client.is_default, position: client.position
        }
      end
    end
  end
end
