require "open3"
require "shellwords"

# Backlog の git リポジトリを shallow clone してローカルにミラーし、
# ファイルツリー・ファイル内容・ブランチ一覧を返す（GitHub風レビュー画面用）。
# Backlog REST API にはファイル内容のエンドポイントが無いため、git 経由で取得する。
class BacklogGitMirror
  CACHE_ROOT = Rails.root.join("tmp", "backlog_git")
  MAX_FILE_BYTES = 500_000 # これ以上のファイルは中身を返さない（UI が固まるため）

  class Error < StandardError; end

  def initialize(client, project_key, repo_name)
    @client = client
    @project_key = project_key
    @repo_name = repo_name
    @dir = CACHE_ROOT.join("#{project_key}_#{repo_name}")
  end

  def cloned? = File.directory?(@dir.join(".git"))

  # clone（初回）or fetch（同期ボタン）。shallow で高速に。
  def sync!
    FileUtils.mkdir_p(CACHE_ROOT)
    if cloned?
      run_git("fetch", "--depth", "50", "origin")
    else
      url = @client.git_https_url(@project_key, @repo_name)
      out, status = Open3.capture2e("git", "clone", "--depth", "50", "--no-single-branch", url, @dir.to_s)
      unless status.success?
        FileUtils.rm_rf(@dir)
        raise Error, "clone失敗: #{sanitize(out).lines.last.to_s.strip[0, 200]}"
      end
    end
    true
  end

  # リモートブランチ一覧（origin/HEAD は除外、デフォルトブランチを先頭に）
  def branches
    ensure_cloned!
    out = run_git("branch", "-r", "--format", "%(refname:short)")
    names = out.lines.map(&:strip).reject { |n| n.include?("HEAD") }.map { |n| n.delete_prefix("origin/") }
    default = default_branch
    ([ default ] + (names - [ default ])).compact
  end

  # ファイルツリー: [{ path:, size: }]（blob のみ、パス昇順）
  def tree(branch)
    ensure_cloned!
    out = run_git("ls-tree", "-r", "-l", "origin/#{branch}")
    out.lines.filter_map do |line|
      # 形式: <mode> <type> <object> <size>\t<path>
      meta, path = line.chomp.split("\t", 2)
      next unless path
      parts = meta.split(/\s+/)
      next unless parts[1] == "blob"
      { path: path, size: parts[3].to_i }
    end.sort_by { |f| f[:path] }
  end

  # ファイル内容（テキスト前提。バイナリ/巨大ファイルはエラー扱い）
  def file(branch, path)
    ensure_cloned!
    raise Error, "不正なパスです" if path.include?("..")
    entry = tree(branch).find { |f| f[:path] == path }
    raise Error, "ファイルが見つかりません: #{path}" unless entry
    raise Error, "ファイルが大きすぎます(#{entry[:size]} bytes)" if entry[:size] > MAX_FILE_BYTES

    content = run_git("show", "origin/#{branch}:#{path}")
    raise Error, "バイナリファイルは表示できません" unless content.valid_encoding? || content.force_encoding("UTF-8").valid_encoding?
    content.force_encoding("UTF-8").scrub("�")
  end

  private

  def default_branch
    out = run_git("symbolic-ref", "refs/remotes/origin/HEAD") rescue nil
    out&.strip&.delete_prefix("refs/remotes/origin/") || "master"
  end

  def ensure_cloned!
    sync! unless cloned?
  end

  def run_git(*args)
    out, status = Open3.capture2e("git", "-C", @dir.to_s, *args)
    raise Error, "git #{args.first} 失敗: #{sanitize(out).lines.last.to_s.strip[0, 200]}" unless status.success?
    out
  end

  # エラーメッセージに認証情報入りURLが混ざっても漏れないように伏せる
  def sanitize(text)
    text.to_s.gsub(%r{https://[^@\s]+@}, "https://***@")
  end
end
