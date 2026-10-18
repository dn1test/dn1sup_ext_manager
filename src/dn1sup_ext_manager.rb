require 'sketchup.rb'
require 'extensions.rb'

# Loader-файл диспетчера расширений. В .rbz лежит в корне архива как dn1sup_ext_manager.rb.
#
# Author: DN1Sup <dn1codegen@gmail.com>
# License: MIT
module Dn1sup
  module ExtManager
    PLUGIN_ROOT = File.dirname(__FILE__).freeze

    # Битый профиль (есть .rb, нет папки с main.rb — частично отзеркаленный
    # Plugins при переключении): пропускаем регистрацию вместо модальной
    # ошибки SketchUp «Failed to load file». Диагностика — в консоли Ruby.
    ENTRY = File.join(PLUGIN_ROOT, 'dn1sup_ext_manager', 'main.rb').freeze
    if File.file?(ENTRY) || File.file?(File.join(PLUGIN_ROOT, 'dn1sup_ext_manager', 'main'))
      extension = SketchupExtension.new('DN1Sup Extension Store', File.join(PLUGIN_ROOT, 'dn1sup_ext_manager', 'main'))
      extension.description = 'Менеджер расширений: каталог, автопоиск расширений на GitHub, установка и обновление .rbz напрямую из GitHub Releases; кнопка на панели инструментов.'
      extension.version     = '0.24.1'
      extension.creator     = 'DN1Sup'
      extension.copyright   = '2026 DN1Sup <dn1codegen@gmail.com> (MIT)'
      extension.id          = 'dn1sup_ext_manager' if extension.respond_to?(:id=)

      Sketchup.register_extension(extension, true)
    else
      warn "[dn1sup_ext_manager] пропущен: нет #{ENTRY} — переустановите расширение или профиль"
    end
  end
end

