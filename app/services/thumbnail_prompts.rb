# YouTube サムネ生成のスタイル定義＋プロンプト参照。
# 日本語プロンプト本文は config/locales/prompts.ja.yml に集約し、ここからは I18n で参照する。
# (GET /api/v1/thumbnails/defaults がフロントへ styles/text_style 等を返す)
module ThumbnailPrompts
  DEFAULT_STYLE = "anime_journey".freeze

  # スタイルの key とフロント表示ラベル。プロンプト本文(template)は I18n から取得する。
  STYLE_DEFS = [
    { key: "proaka",        label: "プロアカ(未経験×AI開発×実績)" },
    { key: "anime_journey", label: "アニメ3コマ(感情変化オチ)" },
    { key: "graphic_only",  label: "人物なし(グラフィック)" },
    { key: "real_person",   label: "実写エンジニア(人物あり)" }
  ].freeze

  # フロント Canvas の文字スタイル初期値(色・フォント等)。フロントはこれを上書き可能。
  DEFAULT_TEXT_STYLE = {
    font_family: "'Noto Sans JP', sans-serif",
    main_color: "#ffffff",
    highlight_color: "#ffe600",
    stroke_color: "#111111",
    sub_color: "#ffffff",
    sub_bg_color: "#e60012"
  }.freeze

  # 生テンプレ取得用。%{title}/%{summary} を「文字列そのまま」で残して返す
  # (フロントの編集欄初期値に使うため、ここでは差し込まない)。
  RAW_VARS = { title: "%{title}", summary: "%{summary}" }.freeze

  module_function

  # フロントへ渡すスタイル一覧(key/label/生テンプレ)。
  def styles
    STYLE_DEFS.map { |s| s.merge(template: style_template(s[:key])) }
  end

  # 後方互換: デフォルトスタイルの生テンプレ。
  def background_template
    style_template(DEFAULT_STYLE)
  end

  def copywriter_system
    I18n.t("prompts.thumbnail.copywriter_system")
  end

  def proofread_system
    I18n.t("prompts.thumbnail.proofread_system")
  end

  # %{title}/%{summary} を実値で差し込んだ背景生成プロンプト。
  def background_prompt(title:, summary:, style: DEFAULT_STYLE)
    key = valid_style_key(style)
    I18n.t("prompts.thumbnail.styles.#{key}", title: title.to_s, summary: summary.to_s)
  end

  # %{title}/%{summary} を残したままの生テンプレ。
  def style_template(style)
    key = valid_style_key(style)
    I18n.t("prompts.thumbnail.styles.#{key}", **RAW_VARS)
  end

  def valid_style_key(style)
    STYLE_DEFS.any? { |s| s[:key] == style.to_s } ? style.to_s : DEFAULT_STYLE
  end
end
