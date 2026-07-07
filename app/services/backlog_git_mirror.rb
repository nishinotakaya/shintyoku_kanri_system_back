require "open3"
require "shellwords"

# Backlog の git リポジトリを shallow clone してローカルにミラーし、
# ファイルツリー・ファイル内容・ブランチ一覧・PR差分を返す（GitHub風レビュー画面用）。
# Backlog REST API にはファイル内容のエンドポイントが無いため、git 経由で取得する。
#
# 並行リクエストで同じミラーに同時 fetch が走ると
# "fatal: shallow file has changed since we read it" になるため、
# リポジトリ単位の flock で git 操作を直列化する。
class BacklogGitMirror
  CACHE_ROOT = Rails.root.join("tmp", "backlog_git")
  MAX_FILE_BYTES = 500_000 # これ以上のファイルは中身を返さない（UI が固まるため）
  FETCH_INTERVAL = 60 # 秒。直近に fetch 済みなら省略（PR を開くたびの fetch 連打を防ぐ）

  class Error < StandardError; end

  def initialize(client, project_key, repo_name)
    # project/repo は params 直渡しなので、パス結合(CACHE_ROOT.join)や clone URL に使う前に書式を検証する
    # ("/" 等を許すと clone 先やロックファイルがキャッシュ外へ逃げられる)
    [ project_key, repo_name ].each do |repository_identifier|
      unless repository_identifier.to_s.match?(/\A[\w.-]+\z/)
        raise Error, "不正なリポジトリ指定です: #{repository_identifier}"
      end
    end
    @client = client
    @project_key = project_key
    @repo_name = repo_name
    @dir = CACHE_ROOT.join("#{project_key}_#{repo_name}")
  end

  def cloned? = File.directory?(@dir.join(".git"))

  # clone（初回）or fetch（同期）。force: false なら直近 FETCH_INTERVAL 秒以内の fetch を省略。
  def sync!(force: true)
    with_lock { sync_unlocked!(force: force) }
  end

  # リモートブランチ一覧（origin/HEAD は除外、デフォルトブランチを先頭に）
  def branches
    with_lock do
      ensure_cloned_unlocked!
      out = run_git("branch", "-r", "--format", "%(refname:short)")
      names = out.lines.map(&:strip).reject { |n| n.include?("HEAD") }.map { |n| n.delete_prefix("origin/") }
      default = default_branch
      ([ default ] + (names - [ default ])).compact
    end
  end

  # ファイルツリー: [{ path:, size: }]（blob のみ、パス昇順）
  def tree(branch)
    with_lock do
      ensure_cloned_unlocked!
      tree_unlocked(branch)
    end
  end

  # ファイル内容（テキスト前提。バイナリ/巨大ファイルはエラー扱い）
  def file(branch, path)
    with_lock do
      ensure_cloned_unlocked!
      raise Error, "不正なパスです" if path.include?("..")
      entry = tree_unlocked(branch).find { |f| f[:path] == path }
      raise Error, "ファイルが見つかりません: #{path}" unless entry
      raise Error, "ファイルが大きすぎます(#{entry[:size]} bytes)" if entry[:size] > MAX_FILE_BYTES

      content = run_git("show", "origin/#{branch}:#{path}")
      raise Error, "バイナリファイルは表示できません" unless content.valid_encoding? || content.force_encoding("UTF-8").valid_encoding?
      content.force_encoding("UTF-8").scrub("�")
    end
  end

  # PR の差分を構造化して返す: [{ path:, lines: [{type: add/del/ctx/hunk, old_no:, new_no:, text:}] }]
  # GitHub の PR 表示と同じく merge-base 起点(three-dot)。shallow で merge-base が無い場合は直接比較にフォールバック。
  def parsed_diff(base_branch, head_branch)
    with_lock do
      ensure_cloned_unlocked!
      raw = begin
        run_git("diff", "origin/#{base_branch}...origin/#{head_branch}")
      rescue Error
        run_git("diff", "origin/#{base_branch}", "origin/#{head_branch}")
      end
      parse_unified_diff(raw.force_encoding("UTF-8").scrub("�"))
    end
  end

  private

  # リポジトリ単位の排他ロック。git 操作の並行実行による shallow ファイル競合を防ぐ。
  def with_lock
    FileUtils.mkdir_p(CACHE_ROOT)
    File.open(CACHE_ROOT.join("#{@project_key}_#{@repo_name}.lock"), File::RDWR | File::CREAT) do |lock_file|
      lock_file.flock(File::LOCK_EX)
      yield
    end
  end

  def sync_unlocked!(force:)
    if cloned?
      return true if !force && recently_fetched?
      run_git("fetch", "--depth", "50", "origin")
      FileUtils.touch(fetch_marker)
    else
      url = @client.git_https_url(@project_key, @repo_name)
      out, status = Open3.capture2e("git", "clone", "--depth", "50", "--no-single-branch", url, @dir.to_s)
      unless status.success?
        FileUtils.rm_rf(@dir)
        raise Error, "clone失敗: #{sanitize(out).lines.last.to_s.strip[0, 200]}"
      end
      FileUtils.touch(fetch_marker)
    end
    true
  end

  def ensure_cloned_unlocked!
    sync_unlocked!(force: true) unless cloned?
  end

  def fetch_marker = CACHE_ROOT.join("#{@project_key}_#{@repo_name}.last_fetch")

  def recently_fetched?
    File.exist?(fetch_marker) && (Time.zone.now - File.mtime(fetch_marker)) < FETCH_INTERVAL
  end

  def tree_unlocked(branch)
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

  def parse_unified_diff(raw)
    files = []
    current = nil
    old_no = new_no = 0
    raw.each_line do |raw_line|
      line = raw_line.chomp
      if line.start_with?("diff --git")
        current = { path: nil, deleted: false, lines: [] }
        files << current
      elsif line.start_with?("--- a/")
        current[:path] ||= line.delete_prefix("--- a/")
      elsif line.start_with?("+++ b/")
        current[:path] = line.delete_prefix("+++ b/")
      elsif line.start_with?("+++ /dev/null")
        current[:deleted] = true
      elsif line.start_with?("Binary files")
        current[:lines] << { type: "hunk", text: "(バイナリファイル)" }
      elsif line.start_with?("@@")
        if line =~ /@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/
          old_no = Regexp.last_match(1).to_i
          new_no = Regexp.last_match(2).to_i
        end
        current[:lines] << { type: "hunk", text: line }
      elsif current && current[:path]
        case line[0]
        when "+"
          current[:lines] << { type: "add", new_no: new_no, text: line[1..].to_s }
          new_no += 1
        when "-"
          current[:lines] << { type: "del", old_no: old_no, text: line[1..].to_s }
          old_no += 1
        when " "
          current[:lines] << { type: "ctx", old_no: old_no, new_no: new_no, text: line[1..].to_s }
          old_no += 1
          new_no += 1
        end
      end
    end
    files.select { |f| f[:path] }
  end

  def default_branch
    out = run_git("symbolic-ref", "refs/remotes/origin/HEAD") rescue nil
    out&.strip&.delete_prefix("refs/remotes/origin/") || "master"
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
