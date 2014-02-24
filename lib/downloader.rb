# -*- coding: utf-8 -*-
#
# Copyright 2013 whiteleaf. All rights reserved.
#

require "yaml"
require "fileutils"
require_relative "narou"
require_relative "sitesetting"
require_relative "template"
require_relative "database"
require_relative "localsetting"
require_relative "narou/api"

#
# 小説サイトからのダウンロード
#
class Downloader
  NOVEL_SITE_SETTING_DIR = "webnovel/"
  SECTION_SAVE_DIR_NAME = "本文"    # 本文を保存するディレクトリ名
  CACHE_SAVE_DIR_NAME = "cache"   # 差分用キャッシュ保存用ディレクトリ名
  RAW_DATA_DIR_NAME = "raw"    # 本文の生データを保存するディレクトリ名
  TOC_FILE_NAME = "toc.yaml"
  WAITING_TIME_FOR_503 = 20   # 503 のときに待機する秒数
  RETRY_MAX_FOR_503 = 5   # 503 のときに何回再試行するか

  attr_reader :id

  #
  # ターゲット(ID、URL、Nコード、小説名)を指定して小説データのダウンロードを開始する
  #
  # force が true なら全話強制ダウンロード
  #
  def self.start(target, force = false, from_download = false)
    setting = nil
    target = Narou.alias_to_id(target)
    case type = get_target_type(target)
    when :url, :ncode
      setting = get_sitesetting_by_target(target)
      unless setting
        error "対応外の#{type}です(#{target})"
        return false
      end
    when :id
      data = @@database[target.to_i]
      unless data
        error "指定のID(#{target})は存在しません"
        return false
      end
      setting = get_sitesetting_by_sitename(data["sitename"])
      setting.multi_match(data["toc_url"], "url")
    when :other
      data = @@database.get_data("title", target)
      if data
        setting = get_sitesetting_by_sitename(data["sitename"])
        setting.multi_match(data["toc_url"], "url")
      else
        error "指定の小説(#{target})は存在しません"
        return false
      end
    end
    downloader = Downloader.new(setting, force, from_download)
    result = downloader.start_download
    setting.clear
    result
  end

  #
  # 小説サイト設定を取得する
  #
  def self.get_sitesetting_by_target(target)
    toc_url = get_toc_url(target)
    setting = nil
    if toc_url
      setting = @@settings.find { |s| s.multi_match(toc_url, "url") }
    end
    setting
  end

  #
  # 本文格納用ディレクトリを取得
  #
  def self.get_novel_section_save_dir(archive_path)
    File.join(archive_path, SECTION_SAVE_DIR_NAME)
  end

  #
  # target の種別を判別する
  #
  # ncodeの場合、targetを破壊的に変更する
  #
  def self.get_target_type(target)
    case target
    when URI.regexp
      :url
    when /^n\d+[a-z]+$/i
      target.downcase!
      :ncode
    when /^\d+$/, Fixnum
      :id
    else
      :other
    end
  end

  #
  # 指定されたIDとかから小説の保存ディレクトリを取得
  #
  def self.get_novel_data_dir_by_target(target)
    target = Narou.alias_to_id(target)
    type = get_target_type(target)
    data = nil
    id = nil
    case type
    when :url, :ncode
      toc_url = get_toc_url(target)
      data = @@database.get_data("toc_url", toc_url)
    when :other
      data = @@database.get_data("title", target)
    when :id
      data = @@database[target.to_i]
    end
    return nil unless data
    id = data["id"]
    file_title = data["file_title"] || data["title"]   # 互換性維持のための処理
    path = File.join(Database.archive_root_path, data["sitename"], file_title)
    if File.exists?(path)
      return path
    else
      @@database.delete(id)
      @@database.save_database
      error "#{path} が見つかりません。"
      warn "保存フォルダが消去されていたため、データベースのインデックスを削除しました。"
      return nil
    end
  end

  #
  # target のIDを取得
  #
  def self.get_id_by_target(target)
    target = Narou.alias_to_id(target)
    toc_url = get_toc_url(target) or return nil
    @@database.get_id("toc_url", toc_url)
  end

  #
  # target からデータベースのデータを取得
  #
  def self.get_data_by_target(target)
    target = Narou.alias_to_id(target)
    toc_url = get_toc_url(target) or return nil
    @@database.get_data("toc_url", toc_url)
  end

  #
  # toc 読込
  #
  def self.get_toc_data(archive_path)
    YAML.load_file(File.join(archive_path, TOC_FILE_NAME))
  end

  #
  # 指定の小説の目次ページのURLを取得する
  #
  # targetがURLかNコードの場合、実際には小説が存在しないURLが返ってくることがあるのを留意する
  #
  def self.get_toc_url(target)
    target = Narou.alias_to_id(target)
    case get_target_type(target)
    when :url
      setting = @@settings.find { |s| s.multi_match(target, "url") }
      return setting["toc_url"] if setting
    when :ncode
      @@database.each do |_, data|
        if data["toc_url"] =~ %r!#{target}/$!
          return data["toc_url"]
        end
      end
      return "#{@@narou["top_url"]}/#{target}/"
    when :id
      data = @@database[target.to_i]
      return data["toc_url"] if data
    when :other
      data = @@database.get_data("title", target)
      return data["toc_url"] if data
    end
    nil
  end

  def self.novel_exists?(target)
    target = Narou.alias_to_id(target)
    id = get_id_by_target(target) or return nil
    @@database.novel_exists?(id)
  end

  def self.remove_novel(target, with_file = false)
    target = Narou.alias_to_id(target)
    data = get_data_by_target(target) or return nil
    data_dir = get_novel_data_dir_by_target(target)
    if with_file
      FileUtils.remove_entry_secure(data_dir)
      puts "#{data_dir} を完全に削除しました"
    else
      # TOCは消しておかないと再DL時に古いデータがあると誤認する
      File.delete(File.join(data_dir, TOC_FILE_NAME))
    end
    @@database.delete(data["id"])
    @@database.save_database
    data["title"]
  end

  def self.get_sitesetting_by_sitename(sitename)
    setting = @@settings.find { |s| s["name"] == sitename }
    return setting if setting
    error "#{data["sitename"]} の設定ファイルが見つかりません"
    exit 1
  end

  #
  # 小説サイトの定義ファイルを全部読み込む
  #
  def self.load_settings
    settings = []
    Dir.glob(File.join(Narou.get_script_dir, NOVEL_SITE_SETTING_DIR, "*.yaml")) do |path|
      setting = SiteSetting.load_file(path)
      if setting["name"] == "小説家になろう"
        @@narou = setting
      end
      settings << setting
    end
    if settings.empty?
      error "小説サイトの定義ファイルがひとつもありません"
      exit 1
    end
    unless @@narou
      error "小説家になろうの定義ファイルが見つかりませんでした"
      exit 1
    end
    settings
  end

  #
  # 差分用キャッシュの保存ディレクトリ取得
  #
  def self.get_cache_root_dir(target)
    dir = get_novel_data_dir_by_target(target)
    if dir
      return File.join(dir, SECTION_SAVE_DIR_NAME, CACHE_SAVE_DIR_NAME)
    end
    nil
  end

  #
  # 差分用キャッシュのディレクトリ一覧取得
  #
  def self.get_cache_list(target)
    dir = get_cache_root_dir(target)
    if dir
      return Dir.glob("#{dir}/*")
    end
    nil
  end

  if Narou.already_init?
    @@settings = load_settings
    @@database = Database.instance
  end

  #
  # コンストラクタ
  #
  def initialize(site_setting, force = false, from_download = false)
    @setting = site_setting
    @force = force
    @from_download = from_download
    @cache_dir = nil
    @new_arrivals = false
    @novel_type = nil
    @id = @@database.get_id("toc_url", @setting["toc_url"]) || @@database.get_new_id
  end

  #
  # 18歳以上か確認する
  #
  def confirm_over18?
    global_setting = GlobalSetting.get["global_setting"]
    if global_setting.include?("over18")
      return global_setting["over18"]
    end
    if Helper.confirm("年齢認証：あなたは18歳以上ですか")
      global_setting["over18"] = true
      GlobalSetting.get.save_settings
      return true
    else
      return false
    end
  end

  #
  # ダウンロード処理本体
  #
  # 返り値：ダウンロードしたものが１話でもあったかどうか(Boolean)
  #         nil なら何らかの原因でダウンロード自体出来なかった
  #
  def start_download
    latest_toc = get_latest_table_of_contents
    unless latest_toc
      error @setting["toc_url"] + " の目次データが取得出来ませんでした"
      return :failed
    end
    if @setting["confirm_over18"]
      unless confirm_over18?
        puts "18歳以上のみ閲覧出来る小説です。ダウンロードを中止しました"
        return :canceled
      end
    end
    old_toc = load_novel_data(TOC_FILE_NAME)
    unless old_toc
      init_novel_dir
      old_toc = {}
      @new_arrivals = true
    end
    init_raw_dir
    if @force
      update_subtitles = latest_toc["subtitles"]
    else
      update_subtitles = update_body_check(old_toc["subtitles"], latest_toc["subtitles"])
    end
    if update_subtitles.count > 0
      unless @force
        if process_digest(old_toc, latest_toc)
          return :canceled
        end
      end
      @cache_dir = create_cache_dir if old_toc.length > 0
      begin
        sections_download_and_save(update_subtitles)
      rescue Interrupt
        remove_cache_dir
        puts "ダウンロードを中断しました"
        exit 1
      end
      update_database
      save_novel_data(TOC_FILE_NAME, latest_toc)
      return :ok
    else
      return :none
    end
  end

  #
  # ダイジェスト化に関する処理
  #
  def process_digest(old_toc, latest_toc)
    return false unless old_toc["subtitles"]
    latest_subtitles_count = latest_toc["subtitles"].count
    old_subtitles_count = old_toc["subtitles"].count
    if latest_subtitles_count < old_subtitles_count
      STDOUT.puts "#{latest_toc["title"]}"
      STDOUT.puts "更新後の話数が保存されている話数より減少していることを検知しました"
      STDOUT.puts "ダイジェスト化されている可能性があるので、更新に関しての処理を選択して下さい"
      digest_output_interface(old_subtitles_count, latest_subtitles_count)
      while input = $stdin.gets
        case input[0]
        when "1"
          return false
        when "2"
          return true
        when "3"
          Command::Freeze.execute_and_rescue_exit([old_toc["title"]])
          return true
        when "4"
          STDOUT.puts "あらすじ"
          STDOUT.puts latest_toc["story"]
        when "5"
          Helper.open_browser(latest_toc["toc_url"])
        end
        digest_output_interface(old_subtitles_count, latest_subtitles_count)
      end
    else
      return false
    end
  end

  def digest_output_interface(old_subtitles_count, latest_subtitles_count)
    STDOUT.puts
    STDOUT.puts "保存済み話数: #{old_subtitles_count}\n更新後の話数: #{latest_subtitles_count}"
    STDOUT.puts
    STDOUT.puts "1: このまま更新する"
    STDOUT.puts "2: 更新をキャンセル"
    STDOUT.puts "3: 更新をキャンセルして小説を凍結する"
    STDOUT.puts "4: 最新のあらすじを表示する"
    STDOUT.puts "5: 小説ページを開く"
    STDOUT.print "選択する処理の番号を入力: "
  end

  #
  # 差分用キャッシュ保存ディレクトリ作成
  #
  def create_cache_dir
    now = Time.now
    name = now.strftime("%Y.%m.%d@%H;%M;%S")
    cache_dir = File.join(get_novel_data_dir, SECTION_SAVE_DIR_NAME, CACHE_SAVE_DIR_NAME, name)
    FileUtils.mkdir_p(cache_dir)
    cache_dir
  end

  #
  # 差分用キャッシュ保存ディレクトリを削除
  #
  def remove_cache_dir
    FileUtils.remove_entry_secure(@cache_dir) if @cache_dir
  end

  #
  # データベース更新
  #
  def update_database
    @@database[@id] = {
      "id" => @id,
      "author" => @setting["author"],
      "title" => @setting["title"],
      "file_title" => @file_title,
      "toc_url" => @setting["toc_url"],
      "sitename" => @setting["name"],
      "novel_type" => get_novel_type,
      "last_update" => Time.now,
      "new_arrivals_date" => (@new_arrivals ? Time.now : @@database[@id]["new_arrivals_date"])
    }
    @@database.save_database
  end

  def get_novel_type
    @novel_type ||= @@database[@id]["novel_type"] || 1
  end

  #
  # 連載小説かどうか調べる
  #
  def serial_novel?
    unless @novel_type
      if @@database[@id]
        @novel_type = get_novel_type
      else
        api = Narou::API.new(@setting, "nt")
        @novel_type = api["novel_type"]
      end
    end
    @novel_type == 1
  end

  #
  # 目次データを取得する
  #
  def get_latest_table_of_contents
    toc_url = @setting["toc_url"]
    return nil unless toc_url
    toc_source = ""
    begin
      open(toc_url) do |toc_fp|
        if toc_fp.base_uri.to_s != toc_url
          # リダイレクトされた場合。
          # ノクターン・ムーンライトのNコードを ncode.syosetu.com に渡すと、novel18.syosetu.com に飛ばされる
          # 目次の定義が微妙に ncode.syosetu.com と違うので、設定を取得し直す
          @setting.clear
          @setting = Downloader.get_sitesetting_by_target(toc_fp.base_uri.to_s)
          toc_url = @setting["toc_url"]
        end
        toc_source = pretreatment_source(toc_fp.read)
      end
    rescue OpenURI::HTTPError => e
      if e.message =~ /^404/
        error "<red>[404]</red> 小説が削除されている可能性があります"
        return false
      else
        raise
      end
    end
    @setting.multi_match(toc_source, "title", "author", "story", "tcode")
    if @setting["narou_api_url"] && serial_novel?
      # 連載小説
      subtitles = get_subtitles(toc_source)
    else
      # 短編小説
      api = Narou::API.new(@setting, "s-gf-nu")
      @setting["story"] = api["story"]
      subtitles = create_short_story_subtitles(api)
    end
    @title = @setting["title"]
    @file_title = Helper.replace_filename_special_chars(@title, invalid_replace: true).strip
    @setting["story"] = @setting["story"].gsub("<br />", "")
    toc_objects = {
      "title" => @title,
      "author" => @setting["author"],
      "toc_url" => @setting["toc_url"],
      "story" => @setting["story"],
      "subtitles" => subtitles
    }
    toc_objects
  end

  def __search_index_in_subtitles(subtitles, index)
    subtitles.index { |item|
      item["index"] == index
    }
  end

  #
  # 本文更新チェック
  #
  # 更新された subtitle だけまとまった配列を返す
  #
  def update_body_check(old_subtitles, latest_subtitles)
    return latest_subtitles unless old_subtitles
    latest_subtitles.dup.keep_if do |latest|
      index = latest["index"]
      index_in_old_toc = __search_index_in_subtitles(old_subtitles, index)
      next true unless index_in_old_toc
      old = old_subtitles[index_in_old_toc]
      # タイトルチェック
      if old["subtitle"] != latest["subtitle"]
        next true
      end
      # 章チェック
      if old["chapter"] != latest["chapter"]
        next true
      end
      # 更新日チェック
      old_subupdate = old["subupdate"]
      latest_subupdate = latest["subupdate"]
      if old_subupdate == ""
        next latest_subupdate != ""
      end
      latest_subupdate > old_subupdate
    end
  end

  #
  # 各話の情報を取得
  #
  def get_subtitles(toc_source)
    subtitles = []
    toc_post = toc_source.dup
    loop do
      match_data = @setting.multi_match(toc_post, "subtitles")
      break unless match_data
      toc_post = match_data.post_match
      subtitles << {
        "index" => @setting["index"],
        "href" => @setting["href"],
        "chapter" => @setting["chapter"],
        "subtitle" => @setting["subtitle"],
        "file_subtitle" => Helper.replace_filename_special_chars(@setting["subtitle"]),
        "subdate" => @setting["subdate"],
        "subupdate" => @setting["subupdate"]
      }
    end
    subtitles
  end

  #
  # 短編用の情報を生成
  #
  def create_short_story_subtitles(api)
    subtitle = {
      "index" => "1",
      "href" => "/",
      "chapter" => "",
      "subtitle" => @setting["title"],
      "file_subtitle" => Helper.replace_filename_special_chars(@setting["title"]),
      "subdate" => api["general_firstup"],
      "subupdate" => api["novelupdated_at"]
    }
    [subtitle]
  end

  #
  # 小説本文をまとめてダウンロードして保存
  #
  # subtitles にダウンロードしたいものをまとめた subtitle info を渡す
  #
  def sections_download_and_save(subtitles)
    max = subtitles.count
    return if max == 0
    puts ("<bold><green>" + TermColor.escape("ID:#{@id}　#{@title} のDL開始") + "</green></bold>").termcolor
    interval_sleep_time = LocalSetting.get["local_setting"]["download.interval"] || 0
    interval_sleep_time = 0 if interval_sleep_time < 0
    save_least_one = false
    subtitles.each_with_index do |subtitle_info, i|
      if @setting["domain"] =~ /syosetu.com/ && (i % 10 == 0 && i >= 10)
        # MEMO:
        # 小説家になろうは連続DL規制があるため、ウェイトを入れる必要がある。
        # 10話ごとに規制が入るため、10話ごとにウェイトを挟む。
        # 1話ごとに1秒待機を10回繰り返そうと、11回目に規制が入るため、ウェイトは必ず必要。
        sleep(5)
      else
        sleep(interval_sleep_time) if i > 0
      end
      index, subtitle, file_subtitle, chapter = %w(index subtitle file_subtitle chapter).map { |k|
                                                  subtitle_info[k]
                                                }
      unless chapter.empty?
        puts "#{chapter}"
      end
      if @novel_type == 1
        print "第#{index}部分"
      else
        print "短編"
      end
      print "　#{subtitle} (#{i+1}/#{max})"
      section_element = a_section_download(subtitle_info)
      info = subtitle_info.dup
      info["element"] = section_element
      section_file_name = "#{index} #{file_subtitle}.yaml"
      section_file_path = File.join(SECTION_SAVE_DIR_NAME, section_file_name)
      if File.exists?(File.join(get_novel_data_dir, section_file_path))
        if @force && different_section?(section_file_path, info)
          print " (更新あり)"
        end
      else
        if !@from_download || (@from_download && @force)
          print " <bold><magenta>(新着)</magenta></bold>".termcolor
        end
        @new_arrivals = true
      end
      move_to_cache_dir(section_file_path)
      save_novel_data(section_file_path, info)
      save_least_one = true
      puts
    end
    remove_cache_dir unless save_least_one
  end

  #
  # すでに保存されている内容とDLした内容が違うかどうか
  #
  def different_section?(relative_path, subtitle_info)
    path = File.join(get_novel_data_dir, relative_path)
    if File.exists?(path)
      return YAML.load_file(path) != subtitle_info
    else
      return true
    end
  end

  #
  # 差分用のキャッシュとして保存
  #
  def move_to_cache_dir(relative_path)
    path = File.join(get_novel_data_dir, relative_path)
    if File.exists?(path) && @cache_dir
      FileUtils.mv(path, @cache_dir)
    end
  end

  #
  # 指定された話数の本文をダウンロード
  #
  def a_section_download(subtitle_info)
    href = subtitle_info["href"]
    if @setting["tcode"]
      subtitle_url = @setting.replace_group_values("txtdownload_url", subtitle_info)
    elsif href[0] == "/"
      subtitle_url = @setting["top_url"] + href
    else
      subtitle_url = @setting["toc_url"] + href
    end
    section = download_raw_data(subtitle_url)
    save_raw_data(section, subtitle_info)
    element = extract_elements_in_section(section, subtitle_info["subtitle"])
    element
  end

  #
  # 指定したURLからデータをダウンロード
  #
  def download_raw_data(url)
    raw = nil
    retry_count = RETRY_MAX_FOR_503
    begin
      open(url) do |fp|
        raw = pretreatment_source(fp.read)
      end
    rescue OpenURI::HTTPError => e
      if e.message =~ /^503/
        if retry_count == 0
          error "上限までリトライしましたがファイルがダウンロード出来ませんでした"
          exit 1
        end
        retry_count -= 1
        warn "server message: #{e.message}"
        warn "リトライ待機中……"
        sleep(WAITING_TIME_FOR_503)
        retry
      else
        raise
      end
    end
    raw
  end

  def get_raw_dir
    File.join(get_novel_data_dir, RAW_DATA_DIR_NAME)
  end

  def init_raw_dir
    path = get_raw_dir
    FileUtils.mkdir_p(path) unless File.exists?(path)
  end

  #
  # テキストデータの生データを保存
  #
  def save_raw_data(raw_data, subtitle_info)
    index = subtitle_info["index"]
    file_subtitle = subtitle_info["file_subtitle"]
    path = File.join(get_raw_dir, "#{index} #{file_subtitle}.txt")
    File.write(path, raw_data)
  end

  #
  # 本文を解析して前書き・本文・後書きの要素に分解する
  #
  # 本文に含まれるタイトルは消す
  #
  def extract_elements_in_section(section, subtitle)
    lines = section.lstrip.lines.map(&:rstrip)
    introduction = slice_introduction(lines)
    postscript = slice_postscript(lines)
    if lines[0] == subtitle.strip
      if lines[1] == ""
        lines.slice!(0, 2)
      else
        lines.slice!(0, 1)
      end
    end
    {
      "introduction" => introduction,
      "body" => lines.join("\n"),
      "postscript" => postscript
    }
  end

  def slice_introduction(lines)
    lines.each_with_index do |line, lineno|
      if line =~ ConverterBase::AUTHOR_INTRODUCTION_SPLITTER
        lines.slice!(lineno, 1)
        return lines.slice!(0...lineno).join("\n")
      end
    end
    ""
  end

  def slice_postscript(lines)
    lines.each_with_index do |line, lineno|
      if line =~ ConverterBase::AUTHOR_POSTSCRIPT_SPLITTER
        lines.slice!(lineno, 1)
        return lines.slice!(lineno..-1).join("\n")
      end
    end
    ""
  end

  #
  # 小説データの格納ディレクトリパス
  def get_novel_data_dir
    raise "小説名がまだ設定されていません" unless @file_title
    File.join(Database.archive_root_path, @setting["name"], @file_title)
  end

  #
  # 小説データの格納ディレクトリに保存
  #
  def save_novel_data(filename, object)
    path = File.join(get_novel_data_dir, filename)
    dir_path = File.dirname(path)
    unless File.exists?(dir_path)
      FileUtils.mkdir_p(dir_path)
    end
    File.write(path, YAML.dump(object))
  end

  #
  # 小説データの格納ディレクトリから読み込む
  def load_novel_data(filename)
    dir_path = get_novel_data_dir
    YAML.load_file(File.join(dir_path, filename))
  rescue Errno::ENOENT
    nil
  end

  #
  # 小説データの格納ディレクトリを初期設定する
  #
  def init_novel_dir
    novel_dir_path = get_novel_data_dir
    FileUtils.mkdir_p(novel_dir_path) unless File.exists?(novel_dir_path)
    default_settings = NovelSetting::DEFAULT_SETTINGS
    special_preset_dir = File.join(Narou.get_preset_dir, @setting["domain"], @setting["ncode"])
    exists_special_preset_dir = File.exists?(special_preset_dir)
    [NovelSetting::INI_NAME, "converter.rb", NovelSetting::REPLACE_NAME].each do |filename|
      if exists_special_preset_dir
        preset_file_path = File.join(special_preset_dir, filename)
        if File.exists?(preset_file_path)
          unless File.exists?(File.join(novel_dir_path, filename))
            FileUtils.cp(preset_file_path, novel_dir_path)
          end
          next
        end
      end
      Template.write(filename, novel_dir_path, binding)
    end
  end

  #
  # ダウンロードしてきたデータを使いやすいように処理
  #
  def pretreatment_source(src)
    restor_entity(src.force_encoding(@setting["encoding"])).gsub("\r", "")
  end

  ENTITIES = { quot: '"', amp: "&", nbsp: " ", lt: "<", gt: ">", copy: "(c)" }
  #
  # エンティティ復号
  #
  def restor_entity(str)
    result = str.dup
    ENTITIES.each do |key, value|
      result.gsub!("&#{key};", value)
    end
    result
  end
end
