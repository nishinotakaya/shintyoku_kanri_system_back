module Api
  module V1
    class FreeeController < BaseController
      # GET /api/v1/freee/setting
      # 現在の接続状態を返す。
      def show_setting
        conn = current_user.freee_connection
        render json: serialize(conn)
      end

      # POST /api/v1/freee/connect
      # body: { identity: "...", password: "..." }
      # sessions API に POST し、200 が返れば接続情報を保存する。
      def connect
        identity = params.require(:identity)
        password = params.require(:password)

        result = Freee::SessionLogin.new(identity: identity, password: password).call
        conn = current_user.freee_connection || current_user.build_freee_connection

        if result.ok?
          conn.assign_attributes(
            identity: identity,
            password_encrypted: password,
            company_id: result.company_id,
            session_cookie: result.session_cookie,
            csrf_token: result.csrf_token,
            last_connected_at: Time.current,
            last_status_code: result.status,
            status: "connected",
            last_error: nil
          )
          conn.save!
          render json: serialize(conn).merge(success: true, message: "freee 接続完了 (200)")
        else
          conn.assign_attributes(
            identity: identity,
            last_status_code: result.status,
            status: "error",
            last_error: result.error.presence || "status=#{result.status}"
          )
          conn.save! if conn.persisted? || conn.identity.present?
          render json: {
            success: false,
            status: result.status,
            error: result.error.presence || "freee 接続に失敗 (status=#{result.status})"
          }, status: :bad_request
        end
      end

      # POST /api/v1/freee/test
      # 保存済みの認証情報で再ログインを試みて、200 が返ってくるか確認する。
      def test_connection
        conn = current_user.freee_connection
        return render(json: { success: false, error: "未接続" }, status: :bad_request) unless conn&.identity

        result = Freee::SessionLogin.new(
          identity: conn.identity,
          password: conn.password_encrypted
        ).call

        if result.ok?
          conn.update!(
            session_cookie: result.session_cookie,
            csrf_token: result.csrf_token,
            last_connected_at: Time.current,
            last_status_code: result.status,
            status: "connected",
            last_error: nil
          )
          render json: { success: true, status: result.status, company_id: result.company_id }
        else
          conn.update!(
            last_status_code: result.status,
            status: "error",
            last_error: result.error.presence || "status=#{result.status}"
          )
          render json: {
            success: false,
            status: result.status,
            error: result.error.presence || "再接続に失敗 (status=#{result.status})"
          }, status: :bad_request
        end
      end

      # DELETE /api/v1/freee/setting
      def disconnect
        current_user.freee_connection&.destroy
        head :no_content
      end

      private

      def serialize(conn)
        {
          connected: conn&.connected? || false,
          identity: conn&.identity,
          company_id: conn&.company_id,
          last_connected_at: conn&.last_connected_at,
          last_status_code: conn&.last_status_code,
          status: conn&.status,
          last_error: conn&.last_error
        }
      end
    end
  end
end
