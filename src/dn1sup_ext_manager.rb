require 'sketchup.rb'
require 'extensions.rb'

# Loader-файл диспетчера расширений. В .rbz лежит в корне архива как dn1sup_ext_manager.rb.
#
# Author: DN1Sup <dn1codegen@gmail.com>
# License: MIT
module Dn1sup
  module ExtManager
    PLUGIN_ROOT = File.dirname(__FILE__).freeze

    extension = SketchupExtension.new('DN1Sup Extension Store', File.join(PLUGIN_ROOT, 'dn1sup_ext_manager', 'main'))
    extension.description = 'Менеджер расширений: каталог, установка и обновление .rbz-расширений напрямую с GitHub Releases; кнопка на панели инструментов.'
    extension.version     = '0.6.3'
    extension.creator     = 'DN1Sup'
    extension.copyright   = '2026 DN1Sup <dn1codegen@gmail.com> (MIT)'
    extension.id          = 'dn1sup_ext_manager' if extension.respond_to?(:id=)

    Sketchup.register_extension(extension, true)
  end
end
