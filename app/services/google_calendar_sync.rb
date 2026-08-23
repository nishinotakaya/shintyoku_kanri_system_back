require "google/apis/calendar_v3"

# プライベートTodo(進捗管理の「プライベート」ワークスペース) ⇄ Google カレンダーの双方向同期。
# 勤怠など既存の予定と混ざらないよう、専用カレンダー「プライベートTodo」を1つ作って
# そこだけを読み書きする(user.private_todo_calendar_id に保持)。
#
# - push(task):   Todo → カレンダーに予定を作成/更新(task.google_event_id で紐付け)
# - remove(task): Todo削除 → 対応イベントを削除
# - import(user, workspace): カレンダーの予定 → プライベートTodo(backlog_tasks source=calendar)に取込(upsert)
#
# トークンは user の google_access_token(必要なら refresh)。calendar スコープが無い場合は
# Google が 403(insufficient scope)を返すので、呼び出し側で「再ログインしてください」を案内する。
class GoogleCalendarSync
  CALENDAR_SUMMARY = "プライベートTodo".freeze
  Cal = Google::Apis::CalendarV3

  class ScopeError < StandardError; end

  def initialize(user)
    @user = user
    # 実際にGoogleへ書き込むトークン保有者(admin=西野に集約される)。
    # 専用カレンダーはこの人のGoogleアカウント内に作られるので、calendar_id もこの人に保存する。
    @token_user = GoogleAuth.writer_user(user)
  end

  # ── 公開API ──

  # Todo をカレンダーへ(なければ作成、あれば更新)。task.google_event_id を保存して返す。
  def push(task)
    service = build_service
    calendar_id = ensure_calendar(service)
    event = build_event(task)
    if task.google_event_id.present?
      begin
        saved = service.update_event(calendar_id, task.google_event_id, event)
      rescue Google::Apis::ClientError => e
        # 既存イベントが手動削除されていたら作り直す
        raise unless e.status_code == 404
        saved = service.insert_event(calendar_id, event)
      end
    else
      saved = service.insert_event(calendar_id, event)
    end
    task.update_column(:google_event_id, saved.id) if saved.id != task.google_event_id
    saved.id
  end

  def remove(task)
    return if task.google_event_id.blank?
    service = build_service
    calendar_id = ensure_calendar(service)
    service.delete_event(calendar_id, task.google_event_id)
  rescue Google::Apis::ClientError => e
    raise unless e.status_code == 404 || e.status_code == 410 # 既に消えている
  end

  # カレンダーの予定を取り込み、プライベートTodo(workspace)に upsert。取込件数を返す。
  def import(workspace, months_back: 1, months_forward: 3)
    service = build_service
    calendar_id = ensure_calendar(service)
    time_min = (Date.current << months_back).to_time.utc.iso8601
    time_max = (Date.current >> months_forward).to_time.utc.iso8601
    imported = 0
    page_token = nil
    loop do
      list = service.list_events(calendar_id, single_events: true, order_by: "startTime",
        time_min: time_min, time_max: time_max, max_results: 250, page_token: page_token)
      (list.items || []).each do |event|
        next if event.status == "cancelled"
        upsert_task_from_event(workspace, event)
        imported += 1
      end
      page_token = list.next_page_token
      break if page_token.blank?
    end
    imported
  end

  private

  def build_service
    service = Cal::CalendarService.new
    service.authorization = GoogleAuth.build_writer(@user)
    service
  rescue => e
    raise ScopeError, e.message
  end

  # 専用カレンダーを取得。無ければ作成しトークン保有者に保存。名前一致の既存があれば再利用。
  def ensure_calendar(service)
    stored_calendar_id = verified_calendar_id(service)
    return stored_calendar_id if stored_calendar_id

    existing = (service.list_calendar_lists.items || []).find { |calendar| calendar.summary == CALENDAR_SUMMARY }
    return claim_calendar_id(service, existing.id, created_now: false) if existing

    created = service.insert_calendar(Cal::Calendar.new(summary: CALENDAR_SUMMARY, time_zone: "Asia/Tokyo"))
    claim_calendar_id(service, created.id, created_now: true)
  rescue Google::Apis::AuthorizationError, Google::Apis::ClientError => e
    # 403 insufficient scope 等
    raise ScopeError, e.message if e.respond_to?(:status_code) && e.status_code == 403
    raise
  end

  # DB に持っている専用カレンダーが今も Google 側にあれば返す。消されていたら nil(=作り直す)。
  def verified_calendar_id(service)
    calendar_id = @token_user.private_todo_calendar_id
    return nil if calendar_id.blank?

    service.get_calendar(calendar_id)
    calendar_id
  rescue Google::Apis::ClientError => e
    raise unless e.status_code == 404
    nil
  end

  # 専用カレンダーの id を1トランザクションで確定させる。
  # 同時リクエストが揃って「まだ無い」と判断した場合は先に登録された方を正とし、
  # 自分が作ってしまった空カレンダーは消す(放置すると同名カレンダーが増え続けるため)。
  def claim_calendar_id(service, calendar_id, created_now:)
    winner_id = @token_user.with_lock do
      stored_calendar_id = @token_user.private_todo_calendar_id
      next stored_calendar_id if stored_calendar_id.present?

      @token_user.update_column(:private_todo_calendar_id, calendar_id)
      calendar_id
    end
    delete_spare_calendar(service, calendar_id) if created_now && winner_id != calendar_id
    winner_id
  end

  # 競合で余った空カレンダーを削除する。消せなくても同期自体は続行させる。
  def delete_spare_calendar(service, calendar_id)
    service.delete_calendar(calendar_id)
  rescue => e
    Rails.logger.warn("[GoogleCalendarSync] 余分な専用カレンダーを削除できませんでした #{calendar_id}: #{e.class}: #{e.message}")
  end

  # Todo → 終日イベント(due_date 優先、無ければ start_date、それも無ければ今日)。
  def build_event(task)
    date = (task.due_date || task.start_date || Date.current)
    Cal::Event.new(
      summary: task.summary.to_s.presence || "(無題のTodo)",
      description: [ task.memo, task.url ].map(&:presence).compact.join("\n"),
      start: Cal::EventDateTime.new(date: date.to_s),
      end: Cal::EventDateTime.new(date: (date + 1).to_s), # 終日は end=翌日
      extended_properties: Cal::Event::ExtendedProperties.new(private: { "shintyoku_task_id" => task.id.to_s })
    )
  end

  # カレンダーの予定 → プライベートTodo。google_event_id で既存を引いて upsert。
  def upsert_task_from_event(workspace, event)
    date = event_date(event)
    task = @user.backlog_tasks.find_by(google_event_id: event.id)
    attrs = {
      summary: event.summary.to_s.presence || "(無題の予定)",
      memo: event.description,
      due_date: date, start_date: date, end_date: date,
      source: "calendar", progress_workspace_id: workspace.id,
      status_id: 1, status_name: "未対応"
    }
    if task
      # 手元で完了(4)にしたものは取込で戻さない
      attrs.delete(:status_id) if task.status_id == 4
      attrs.delete(:status_name) if task.status_id == 4
      task.update!(attrs)
    else
      @user.backlog_tasks.create!(attrs.merge(
        issue_key: "GC-#{SecureRandom.hex(3).upcase}", google_event_id: event.id, created_on: Date.current))
    end
  end

  def event_date(event)
    raw = event.start&.date || event.start&.date_time
    return Date.current if raw.blank?
    raw.respond_to?(:to_date) ? raw.to_date : Date.parse(raw.to_s)
  end
end
