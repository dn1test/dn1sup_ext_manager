require 'sketchup.rb'
require 'extensions.rb'

# Loader-файл диспетчера расширений. В .rbz лежит в корне архива как dn1sup_ext_manager.rb.
module Dn1sup
  module ExtManager
    PLUGIN_ROOT = File.dirname(__FILE__).freeze

    extension = SketchupExtension.new('DN1Sup Extension Store', File.join(PLUGIN_ROOT, 'dn1sup_ext_manager', 'main'))
    extension.description = 'Менеджер расширений: установка и обновление .rbz-расширений напрямую с GitHub Releases по JSON-реестру.'
    extension.version     = '0.3.0'
    extension.creator     = 'DN1Sup'
    extension.copyright   = '2026 DN1Sup'
    extension.id          = 'dn1sup_ext_manager' if extension.respond_to?(:id=)

    Sketchup.register_extension(extension, true)
  end
end
