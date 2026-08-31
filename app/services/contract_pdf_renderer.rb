require "open3"
require "fileutils"
require "erb"
require "base64"

# 業務委託契約書 PDF を生成。
# Contract の内容(下書き/送付済み/署名済み)を HTML → PDF に変換。
class ContractPdfRenderer
  TEMPLATE = Rails.root.join("app/views/contracts/contract.html.erb")
  SCRIPT   = Rails.root.join("lib/exporters/html_to_pdf.mjs")

  # 甲(発行者)の印影。氏名(空白除去)の完全一致でのみ判定する(苗字の前方一致はしない)。
  HANKO_MAP = { "西野鷹也" => "hanko_nishino.png", "川村卓也" => "hanko_kawamura.svg" }.freeze

  def initialize(contract)
    @contract = contract
  end

  def call
    data = build_data
    html_body = ERB.new(File.read(TEMPLATE)).result_with_hash(data: data)

    out_dir = Rails.root.join("tmp/exports")
    FileUtils.mkdir_p(out_dir)
    stamp = SecureRandom.hex(4)
    html_path = out_dir.join("contract_#{@contract.id}_#{stamp}.html").to_s
    pdf_path  = html_path.sub(/\.html$/, ".pdf")
    File.write(html_path, html_body)

    _, err, status = Open3.capture3("node", SCRIPT.to_s, html_path, pdf_path)
    raise "html_to_pdf failed: #{err}" unless status.success?
    pdf_path
  ensure
    File.delete(html_path) if defined?(html_path) && html_path && File.exist?(html_path)
  end

  # PDF のバイト列を返し、一時ファイルはその場で消す。乙が何度も PDF を開く運用なので
  # tmp/exports に生成物を溜めない(send_file だと配信中に消せないため send_data で使う)。
  def render_bytes
    pdf_path = call
    File.binread(pdf_path)
  ensure
    File.delete(pdf_path) if pdf_path && File.exist?(pdf_path)
  end

  private

  def build_data
    {
      title: @contract.title.to_s,
      is_draft: @contract.status == "draft",
      is_signed: @contract.status == "signed",
      party_a: @contract.party_a_hash,
      party_b: @contract.party_b_hash,
      contract_date: @contract.contract_date&.iso8601,
      start_on: @contract.start_on&.iso8601,
      end_on: @contract.end_on&.iso8601,
      articles: normalized_articles,
      special_terms: @contract.special_terms.to_s,
      signed_at: @contract.signed_at,
      signature_image: @contract.signature_image,
      content_sha256: @contract.content_sha256,
      contract_id: @contract.id,
      hanko_src: hanko_src
    }
  end

  def normalized_articles
    Array(@contract.articles).map do |article|
      indifferent = article.is_a?(Hash) ? article.with_indifferent_access : {}
      { heading: indifferent[:heading].to_s, body: indifferent[:body].to_s }
    end
  end

  def hanko_src
    db_seal = @contract.user.seal_image
    return db_seal if db_seal.present?

    normalized_name = @contract.user.display_name.to_s.gsub(/[\s　]/, "")
    hanko_file = HANKO_MAP[normalized_name]
    return nil unless hanko_file

    hanko_path = Rails.root.join("public", hanko_file)
    return nil unless File.exist?(hanko_path)

    mime = hanko_file.end_with?(".svg") ? "image/svg+xml" : "image/png"
    "data:#{mime};base64,#{Base64.strict_encode64(File.binread(hanko_path))}"
  end
end
