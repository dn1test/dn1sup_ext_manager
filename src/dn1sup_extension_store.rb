require 'sketchup.rb'
require 'extensions.rb'

# Loader-файл диспетчера расширений. В .rbz лежит в корне архива как dn1sup_extension_store.rb.
#
# Author: DN1Sup <dn1codegen@gmail.com>
# License: MIT
module Dn1sup
  module ExtensionStore
    PLUGIN_ROOT = File.dirname(__FILE__).freeze

    # Битый профиль (есть .rb, нет папки с main.rb — частично отзеркаленный
    # Plugins при переключении): пропускаем регистрацию вместо модальной
    # ошибки SketchUp «Failed to load file». Диагностика — в консоли Ruby.
    ENTRY = File.join(PLUGIN_ROOT, 'dn1sup_extension_store', 'main.rb').freeze
    if File.file?(ENTRY) || File.file?(File.join(PLUGIN_ROOT, 'dn1sup_extension_store', 'main'))
      extension = SketchupExtension.new('DN1Sup Extension Store', File.join(PLUGIN_ROOT, 'dn1sup_extension_store', 'main'))
      extension.description = 'Менеджер расширений: каталог, автопоиск расширений на GitHub, установка и обновление .rbz напрямую из GitHub Releases; кнопка на панели инструментов.'
      extension.version     = '0.29.1'
      extension.creator     = 'DN1Sup'
      extension.copyright   = '2026 DN1Sup <dn1codegen@gmail.com> (MIT)'
      extension.id          = 'dn1sup_extension_store' if extension.respond_to?(:id=)

      Sketchup.register_extension(extension, true)
    else
      warn "[dn1sup_extension_store] пропущен: нет #{ENTRY} — переустановите расширение или профиль"
    end

    # Устаревшая установка под старым именем: предупредим о двойнике.
    legacy_loader = File.join(File.dirname(__FILE__), 'dn1sup_ext_manager.rb')
    if File.file?(legacy_loader)
      warn '[dn1sup_extension_store] найден устаревший dn1sup_ext_manager.rb — ' \
           'удалите старое расширение dn1sup_ext_manager из Plugins, чтобы не было дубля'
    end
  end
end

