class CreateWorkReportMeterPhotos < ActiveRecord::Migration[8.0]
  def change
    create_table :work_report_meter_photos do |t|
      t.references :work_report, null: false, foreign_key: true
      t.string :kind, null: false # start / end
      t.string :content_type
      t.binary :data
      t.timestamps
    end
    add_index :work_report_meter_photos, [ :work_report_id, :kind ], unique: true
  end
end
