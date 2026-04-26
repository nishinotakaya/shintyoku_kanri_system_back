class WorkReportBulkApplier
  def initialize(user, ops, category: "wings")
    @user = user
    @ops = ops || []
    @category = category
  end

  def call
    applied = []
    ActiveRecord::Base.transaction do
      @ops.each do |op|
        from = Date.parse(op[:from])
        to   = Date.parse(op[:to])
        (from..to).each do |date|
          report = @user.work_reports.find_or_initialize_by(work_date: date, category: @category)
          report.hours   = op[:hours]   unless op[:hours].nil?
          report.content = op[:content] unless op[:content].nil?
          report.save!
          applied << report
        end
      end
    end
    applied
  end
end
