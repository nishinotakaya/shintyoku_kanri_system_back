module Api
  module V1
    class WorkReportsController < BaseController
      before_action :set_report, only: [ :update, :destroy, :meter_photo, :expense_photo ]
      before_action :set_report_for_approval, only: [ :approve, :unapprove ]

      def index
        year, month = parse_month
        target = viewing_user
        period = target.period_for(year, month)
        reports = target.work_reports.in_range(period)
        photo_kinds = WorkReportMeterPhoto.where(work_report_id: reports.map(&:id))
                                          .pluck(:work_report_id, :kind)
                                          .group_by(&:first).transform_values { |pairs| pairs.map(&:last) }
        expense_photo_rows = WorkReportExpensePhoto.where(work_report_id: reports.map(&:id))
                                                   .order(:id)
                                                   .pluck(:work_report_id, :id, :amount, :label)
                                                   .group_by(&:first)
                                                   .transform_values { |rows| rows.map { |(_, id, amount, label)| { id: id, amount: amount, label: label } } }
        render json: {
          period: { from: period.first, to: period.last },
          reports: reports.map { |r| serialize(r, meter_photo_kinds: photo_kinds[r.id] || [], expense_photos: expense_photo_rows[r.id] || []) },
          viewing: { id: target.id, display_name: target.display_name }
        }
      end

      def create
        cat = params[:category].presence || viewing_user.visible_work_categories.first
        report = viewing_user.work_reports.find_or_initialize_by(work_date: params[:work_date], category: cat)
        attrs = report_params
        # リビング案件は乗車区間・交通費を持たない (連携・保存ともに無効化)
        if cat == "living"
          attrs[:transit_section] = nil
          attrs[:transit_fee] = nil
        end
        report.assign_attributes(attrs)
        report.save!
        apply_meter_photo_params(report)
        apply_expense_photo_params(report)
        sync_expense_from_report(report)
        render json: serialize(report), status: :created
      end

      def update
        @report.update!(report_params)
        apply_meter_photo_params(@report)
        apply_expense_photo_params(@report)
        sync_expense_from_report(@report)
        render json: serialize(@report)
      end

      # POST /api/v1/work_reports/read_meter (multipart: file=メーター写真)
      # 写真をAIで読み取り、走行距離(km)を返す。保存はしない(保存は create/update の photo params で行う)。
      def read_meter
        file = params[:file]
        return render(json: { error: "メーター写真を添付してください" }, status: :unprocessable_entity) unless file.respond_to?(:read)

        bytes = file.read
        content_type = file.respond_to?(:content_type) ? file.content_type : "image/jpeg"
        result = MeterPhotoReader.call(bytes, content_type)
        return render(json: { error: result[:error] }, status: :unprocessable_entity) if result[:error]

        render json: { value: result[:value], confidence: result[:confidence] }
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/v1/work_reports/read_expense (multipart: file=レシート写真)
      # 実費レシートをAIで読み取り、金額と内容を返す。保存はしない(保存は create/update の photo params で行う)。
      def read_expense
        file = params[:file]
        return render(json: { error: "レシート写真を添付してください" }, status: :unprocessable_entity) unless file.respond_to?(:read)

        bytes = file.read
        content_type = file.respond_to?(:content_type) ? file.content_type : "image/jpeg"
        result = ExpensePhotoReader.call(bytes, content_type)
        return render(json: { error: result[:error] }, status: :unprocessable_entity) if result[:error]

        render json: { amount: result[:amount], label: result[:label], confidence: result[:confidence] }
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # GET /api/v1/work_reports/:id/expense_photo?photo_id=
      def expense_photo
        photo = @report.expense_photos.find_by(id: params[:photo_id])
        return head :not_found unless photo&.data.present?

        content_type = photo.content_type
        content_type = "image/jpeg" unless WorkReportExpensePhoto::ALLOWED_CONTENT_TYPES.include?(content_type)
        send_data photo.data, type: content_type, disposition: "inline"
      end

      # GET /api/v1/work_reports/:id/meter_photo?kind=start|end
      def meter_photo
        photo = @report.meter_photos.find_by(kind: params[:kind])
        return head :not_found unless photo&.data.present?

        content_type = photo.content_type
        content_type = "image/jpeg" unless WorkReportMeterPhoto::ALLOWED_CONTENT_TYPES.include?(content_type)
        send_data photo.data, type: content_type, disposition: "inline"
      end

      def destroy
        @report.destroy!
        head :no_content
      end

      # PATCH /api/v1/work_reports/:id/approve
      def approve
        @report.approve!(actor: current_user)
        render json: serialize(@report)
      end

      # DELETE /api/v1/work_reports/:id/approve
      def unapprove
        @report.unapprove!
        render json: serialize(@report)
      end

      def clock_in
        cat = params[:category].presence || current_user.visible_work_categories.first
        report = current_user.work_reports.find_or_initialize_by(work_date: Date.current, category: cat)
        report.clock_in ||= Time.current
        report.save!
        render json: serialize(report)
      end

      def clock_out
        cat = params[:category].presence || current_user.visible_work_categories.first
        report = current_user.work_reports.find_or_initialize_by(work_date: Date.current, category: cat)
        report.clock_out = Time.current
        # 稼働時間は WorkReport の before_save が開始・終了から算出する(打刻・手入力で共通)
        report.save!
        render json: serialize(report)
      end

      def voice_command
        parsed = WorkReportCommandParser.new(
          text: params[:text],
          user: current_user,
          base_date: Date.current,
          selected_range: params[:selected_range]
        ).call
        cat = params[:category].presence || current_user.visible_work_categories.first
        applied = WorkReportBulkApplier.new(current_user, parsed[:ops], category: cat).call
        render json: { ops: parsed[:ops], applied: applied.map { |r| serialize(r) } }
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      def transcribe
        file = params[:audio]
        return render(json: { error: "audio missing" }, status: :bad_request) unless file
        text = OpenaiClient.transcribe(file.tempfile, user: current_user)
        render json: { text: text }
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # 設定保存時: 通勤日の全業務報告に乗車区間・交通費を一括反映 + 立替金も
      def apply_transit
        year, month = parse_month
        period = current_user.period_for(year, month)
        commute_days = (current_user.commute_days || [ 1, 2, 3, 4, 5 ]).map(&:to_i).to_set
        custom_off = (current_user.custom_off_days || []).map { |d| Date.parse(d) rescue nil }.compact.to_set
        from = current_user.default_transit_from
        to = current_user.default_transit_to
        fee = current_user.default_transit_fee
        line = current_user.default_transit_line
        cat = params[:category] || current_user.visible_work_categories.first

        return render(json: { applied: 0 }) unless from.present? && fee.to_i > 0

        section = "#{from} ~ #{to}"
        count = 0

        ActiveRecord::Base.transaction do
          # 期間内の立替金を一旦全削除して再作成
          current_user.expenses.where(expense_date: period, category: cat).destroy_all

          period.each do |date|
            next if date.saturday? || date.sunday?
            next if custom_off.include?(date)

            if commute_days.include?(date.wday)
              wr = current_user.work_reports.find_or_initialize_by(work_date: date, category: cat)
              wr.transit_section = section
              wr.transit_fee = fee
              wr.save!

              expense = current_user.expenses.find_or_initialize_by(
                expense_date: date, category: cat, from_station: from, to_station: to
              )
              expense.purpose ||= "顧客先出張"
              expense.transport_type ||= "train"
              expense.round_trip = true if expense.round_trip.nil?
              expense.receipt_no ||= "無"
              expense.amount = fee
              expense.payee_or_line ||= line
              expense.save!

              count += 1
            else
              wr = current_user.work_reports.find_by(work_date: date, category: cat)
              wr&.update!(transit_section: nil, transit_fee: nil) if wr&.transit_fee.to_i > 0
            end
          end
        end

        render json: { applied: count }
      end

      def import_progress
        file = params[:file]
        return render(json: { error: "file missing" }, status: :bad_request) unless file
        year, month = parse_month
        cat = params[:category].presence || current_user.visible_work_categories.first

        tmp = Rails.root.join("tmp", "progress_#{SecureRandom.hex(4)}.xlsx")
        File.open(tmp, "wb") { |f| f.write(file.read) }

        reports = ProgressImporter.new(
          user: current_user, file: tmp, year: year, month: month,
          daily_hours: params[:daily_hours]&.to_f || 7.5
        ).call

        if params[:apply] == "true"
          applied = []
          ActiveRecord::Base.transaction do
            reports.each do |r|
              wr = current_user.work_reports.find_or_initialize_by(work_date: r[:date], category: cat)
              wr.content = r[:content]
              wr.hours = r[:hours]
              wr.save!
              applied << serialize(wr)
            end
          end
          render json: { applied: applied, count: applied.size }
        else
          render json: { preview: reports, count: reports.size }
        end
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      ensure
        File.delete(tmp) if defined?(tmp) && tmp && File.exist?(tmp)
      end

      # タスクを業務報告に追記（既存があれば追記、なければ作成）
      # params: work_date, category, issue_key, hours, target_assignee（省略時は current_user）
      def append_task
        target = resolve_target_user(params[:target_assignee])
        unless target == current_user || admin_user?(current_user)
          return render(json: { error: "他ユーザーへの追加権限がありません" }, status: :forbidden)
        end
        cat = params[:category].presence || target.visible_work_categories.first
        issue_key = params[:issue_key].to_s
        # LOCAL-XXX (ローカル作成タスク) は summary をキーとして展開する。
        # 理由: LOCAL-9ECA30 の hex 部分が SAP 形式 (LETTERS-NUMBERS) にマッチせず、
        #       フロントの parseSapEntries で時間が認識されなくなるため。
        if issue_key.start_with?("LOCAL-")
          local_task = target.backlog_tasks.find_by(issue_key: issue_key)
          if local_task&.summary.present?
            issue_key = local_task.summary.gsub(%r{[/()]}, " ").squish[0..30]
          end
        end
        hours = params[:hours].to_f
        report = target.work_reports.find_or_initialize_by(work_date: params[:work_date], category: cat)
        existing_content = report.content.to_s
        entry_str = hours > 0 ? "#{issue_key}(#{format_hours(hours)})" : issue_key
        report.content = existing_content.empty? ? entry_str : "#{existing_content}/#{entry_str}"
        report.hours = (report.hours.to_f + hours)
        report.save!
        render json: serialize(report).merge(target_user: target.display_name)
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      private

      # 苗字「西野」での判定は同姓の一般ユーザーも管理者扱いにしてしまうので、User#admin? に寄せる
      def admin_user?(user)
        user.admin?
      end

      def resolve_target_user(target_assignee)
        return current_user if target_assignee.blank?
        surname = current_user.display_name.to_s.split(/[\s　]/).first.to_s
        return current_user if target_assignee.to_s.include?(surname) || surname.include?(target_assignee.to_s)
        User.where("display_name LIKE ?", "%#{target_assignee}%").first || current_user
      end

      def format_hours(h)
        h == h.to_i ? h.to_i.to_s : ("%.1f" % h)
      end

      def set_report
        # admin は他ユーザーの work_report も編集可（viewing_user 経由）
        @report = viewing_user.work_reports.find(params[:id])
      end

      # 検印は「所有者本人」または admin だけが押せる。viewing_user 経由(admin専用の as_user_id 切替)には
      # 乗らず、リクエストしたユーザー自身が所有者かどうかを直接見て 403 を返す。
      def set_report_for_approval
        @report = WorkReport.find(params[:id])
        return if @report.user_id == current_user.id || admin_user?(current_user)

        render json: { error: "検印を押す権限がありません" }, status: :forbidden
      end

      # 乗車区間・交通費 → 立替金に自動同期（report の所属ユーザーで連動）
      def sync_expense_from_report(report)
        cat = report.category || "wings"
        owner = report.user

        # リビング案件は乗車区間・交通費を持たない仕様 → 同期スキップ
        return if cat == "living"

        if report.transit_section.present? && report.transit_fee.to_i > 0
          parts = report.transit_section.split(/\s*[~～〜\-\s]+/)
          from = parts[0].to_s.strip
          to = parts[1].to_s.strip

          expense = owner.expenses.find_or_initialize_by(
            expense_date: report.work_date, category: cat
          )
          expense.from_station = from
          expense.to_station = to
          expense.purpose ||= "顧客先出張"
          expense.transport_type ||= "train"
          expense.round_trip = true if expense.round_trip.nil?
          expense.receipt_no ||= "無"
          expense.amount = report.transit_fee
          expense.payee_or_line ||= owner.default_transit_line
          expense.save!
        else
          # 乗車区間が空になったら立替金も削除
          owner.expenses.where(expense_date: report.work_date, category: cat).destroy_all
        end
      end

      # メーター写真の保存/削除。値は data URL(data:image/jpeg;base64,...) で受け取る。
      # 写真クリア時は remove_meter_{start,end}_photo=true が来る(値のクリアは meter_start/end 側で行われる)。
      def apply_meter_photo_params(report)
        { "start" => [ :meter_start_photo_base64, :remove_meter_start_photo ],
          "end"   => [ :meter_end_photo_base64, :remove_meter_end_photo ] }.each do |kind, (data_key, remove_key)|
          if params[data_key].present?
            content_type, bytes = decode_data_url(params[data_key])
            next if bytes.blank?
            content_type = "image/jpeg" unless WorkReportMeterPhoto::ALLOWED_CONTENT_TYPES.include?(content_type)
            photo = report.meter_photos.find_or_initialize_by(kind: kind)
            photo.update!(content_type: content_type, data: bytes)
          elsif ActiveModel::Type::Boolean.new.cast(params[remove_key])
            report.meter_photos.find_by(kind: kind)&.destroy!
          end
        end
      end

      # 実費レシート写真の追加/削除。
      # expense_photos_add: [{ data_base64(data URL), amount, label }] / remove_expense_photo_ids: [id]
      def apply_expense_photo_params(report)
        Array(params[:remove_expense_photo_ids]).each do |photo_id|
          report.expense_photos.find_by(id: photo_id)&.destroy!
        end
        Array(params[:expense_photos_add]).each do |photo_params|
          data_value = photo_params[:data_base64].presence
          next if data_value.blank?
          content_type, bytes = decode_data_url(data_value)
          next if bytes.blank?
          content_type = "image/jpeg" unless WorkReportExpensePhoto::ALLOWED_CONTENT_TYPES.include?(content_type)
          report.expense_photos.create!(
            content_type: content_type,
            data: bytes,
            amount: photo_params[:amount].presence&.to_i,
            label: photo_params[:label].to_s.strip.presence
          )
        end
      end

      def decode_data_url(value)
        if value =~ %r{\Adata:([^;]+);base64,(.+)\z}m
          [ Regexp.last_match(1), (Base64.strict_decode64(Regexp.last_match(2)) rescue nil) ]
        else
          [ "image/jpeg", (Base64.strict_decode64(value) rescue nil) ]
        end
      end

      def report_params
        # approved_by_id はここでは受け付けない(検印は approve!/unapprove! 経由でのみ更新する)
        params.permit(:work_date, :content, :hours, :clock_in, :clock_out,
                      :break_minutes, :transit_section, :transit_fee, :category,
                      :distance_km, :delivery_count, :meter_start, :meter_end,
                      :note, :weekly_payment)
      end

      def serialize(r, meter_photo_kinds: nil, expense_photos: nil)
        {
          meter_photo_kinds: meter_photo_kinds || r.meter_photos.pluck(:kind),
          expense_photos: expense_photos ||
            r.expense_photos.order(:id).pluck(:id, :amount, :label).map { |(id, amount, label)| { id: id, amount: amount, label: label } },
          id: r.id, work_date: r.work_date, content: r.content,
          hours: r.hours&.to_f, clock_in: r.clock_in&.strftime("%H:%M"),
          clock_out: r.clock_out&.strftime("%H:%M"),
          break_minutes: r.break_minutes,
          transit_section: r.transit_section, transit_fee: r.transit_fee,
          category: r.category,
          distance_km: r.distance_km&.to_f, delivery_count: r.delivery_count,
          meter_start: r.meter_start, meter_end: r.meter_end,
          note: r.note, weekly_payment: r.weekly_payment,
          approved: r.approved?, approved_at: r.approved_at&.iso8601,
          approved_by: r.approved_by && { id: r.approved_by.id, display_name: r.approved_by.display_name }
        }
      end
    end
  end
end
