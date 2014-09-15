#coding: utf-8

Plugin.create(:test) { 

  # 検索データソースを管理するCRUDクラス
  class DataSourceList < Gtk::CRUD
    PREFIX= "datasource_search"

    # スラッグを得る
    def get_slug(str)
      "#{PREFIX}_#{str.to_s}".to_sym
    end

    # ヘッダ部の定義
    def column_schemer
      [
        {:type => Symbol, :label => "スラッグ（隠し）"},
        {:kind => :text, :type => String, :label => "データソース名"},
        {:kind => :text, :type => String, :label => "クエリ"},
      ]
    end

    # 設定ファイルに値を書き込む
    def store_item(slug, item)
      config = if UserConfig[:datasource_search]
        UserConfig[:datasource_search]
      else
        {}
      end.melt

      if item
        config[slug.to_sym] = item
      else
        config.delete(slug.to_sym)
      end

      UserConfig[:datasource_search] = config
    end

    # リストに項目を追加する
    def set_treeview_item(iter, slug, item)
      iter[0] = slug
      iter[1] = item[:name]
      iter[2] = item[:query]
    end

    # コンストラクタ
    def initialize(*args)
      super(*args)

      # リストを表示する
      if UserConfig[:datasource_search]
        UserConfig[:datasource_search].each { |slug, item|
          iter = model.model.append
          set_treeview_item(iter, slug, item)
        }
      end
    end

    # 項目追加
    def force_record_create(item)
      if item
        slug = get_slug(Time.now.to_i)
        iter = model.model.append

        store_item(slug, item)
        set_treeview_item(iter, slug, item)

        Plugin.call(:datasource_search_update, slug)
      end
    end

    # 項目更新
    def force_record_update(iter, item)
      if item
        store_item(iter[0], item)
        set_treeview_item(iter, iter[0], item)

        Plugin.call(:datasource_search_update, iter[0].to_sym)
      end
    end

    # 項目削除
    def force_record_delete(iter)
      store_item(iter[0].to_sym, nil)

      model.model.remove(iter)
    end

    # 設定ダイアログを表示する
    def popup_input_window(defaults = [])
      config = if defaults.length != 0
        UserConfig[:datasource_search][defaults[0].to_sym]
      else
        {}
      end

      parent_window = if self
        self
      elsif self.toplevel.toplevel?
        self.toplevel
      end

      result = nil

      dialog = Gtk::Dialog.new("検索データソース - #{Environment::NAME}", parent_window, Gtk::Dialog::MODAL)
      dialog.window_position = Gtk::Window::POS_CENTER

      widgets = {}

      widgets[:name_box] = Gtk::HBox.new
      widgets[:name_label] = Gtk::Label.new("データソース名")
      widgets[:name_edit] = Gtk::Entry.new

      if config[:name]
        widgets[:name_edit].set_text(config[:name])
      end

      widgets[:name_box].pack_start(widgets[:name_label], false, 5)
      widgets[:name_box].pack_start(widgets[:name_edit])

      widgets[:query_box] = Gtk::HBox.new
      widgets[:query_label] = Gtk::Label.new("検索文字列")
      widgets[:query_edit] = Gtk::Entry.new

      if config[:query]
        widgets[:query_edit].set_text(config[:query])
      end

      widgets[:query_box].pack_start(widgets[:query_label], false)
      widgets[:query_box].pack_start(widgets[:query_edit])

      widgets[:ja_only] = Gtk::CheckButton.new("日本語のツイートのみ")
      widgets[:ja_only].active = config[:ja_only]
      
      dialog.vbox.pack_start(widgets[:name_box], false)
      dialog.vbox.pack_start(widgets[:query_box], false)
      dialog.vbox.pack_start(widgets[:ja_only], false)

      widgets[:ok_button] = dialog.add_button(Gtk::Stock::OK, Gtk::Dialog::RESPONSE_OK)
      widgets[:cancel_button] = dialog.add_button(Gtk::Stock::CANCEL, Gtk::Dialog::RESPONSE_CANCEL)

      widgets[:ok_button].sensitive = false

      dialog.signal_connect('response') { |widget, response|
        if response == ::Gtk::Dialog::RESPONSE_OK
            result = {
              :name => widgets[:name_edit].text,
              :query => widgets[:query_edit].text,
              :ja_only => widgets[:ja_only].active?,
            }

            dialog.destroy
        else
          result = nil
          dialog.destroy
        end
      }

      [widgets[:name_edit], widgets[:query_edit]].each { |entry|
        entry.signal_connect('changed') { |widget|
          widgets[:ok_button].sensitive = [widgets[:name_edit], widgets[:query_edit]].all? { |entry2|
            puts entry2.text.gsub(/[ \t]+/, "").empty?
            !entry2.text.gsub(/[ \t]+/, "").empty?
          }
        }
      }

      dialog.show_all
      dialog.run

      result
    end
  end

  # 起動時処理
  on_boot { |service|
    refresh_all
  }

  # 定期的にイベントを発生させる
  counter = gen_counter

  on_period { |service|
    if counter.call >= UserConfig[:retrieve_interval_search]
      counter = gen_counter
      refresh_all
    end
  }

  # 全ての検索データソースを再検索する
  def refresh_all
    if UserConfig[:datasource_search]
      UserConfig[:datasource_search].each { |slug, item|
        refresh(slug)
      }
    end
  end

  # 検索データソースを検索する
  def refresh(slug)
    item = UserConfig[:datasource_search][slug]
    params = {}
    params[:q] = item[:query]
    params[:count] = 100

    if item[:ja_only]
      params[:lang] = "ja"
    end

    Service.primary.search(params).next{ |res|
      Plugin.call(:extract_receive_message, slug.to_sym, Messages.new(res))
    }
  end

  # 抽出タブの条件変更
  on_extract_tab_update { |extract|
    # データソースに検索データソースが含まれる場合、再検索する
    extract[:sources].select { |source| UserConfig[:datasource_search][source] }.each { |source|
      refresh(source)
    }
  }

  # 検索データソースの内容が変更された
  on_datasource_search_update { |slug|
    # 当該データソースを再建策
    refresh(slug)
  }

  # 設定
  settings("検索データソース") {
    listview = Plugin::DataSourceList.new
    pack_start(Gtk::HBox.new(false, 4).add(listview).closeup(listview.buttons(Gtk::VBox)))
  }

  # 抽出タブ一覧
  filter_extract_datasources { |datasources|
    if UserConfig[:datasource_search]
      UserConfig[:datasource_search].each { |slug, item|
        datasources[slug.to_sym] = item[:name]
      }
    end

    [datasources]
  }
}
