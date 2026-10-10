# One-off: sync shared/dn1sup_updater.rb into sibling dn1sup repos (run manually).
base = File.expand_path('..', __dir__)
master = File.join(base, 'shared', 'dn1sup_updater.rb')
targets = %w[
  dn1sup_autoselect_tag/shared/dn1sup_updater.rb
  dn1sup_autoselect_tag/dn1sup_autoselect_tag/dn1sup_autoselect_tag/dn1sup_updater.rb
  dn1sup_comp_add_view/shared/dn1sup_updater.rb
  dn1sup_create_project/shared/dn1sup_updater.rb
  dn1sup_save_settings/shared/dn1sup_updater.rb
  dn1sup_time_project/shared/dn1sup_updater.rb
]
require 'digest'
require 'fileutils'
targets.each do |t|
  path = File.expand_path(t, File.join(base, '..'))
  next unless File.file?(path)

  same = Digest::SHA256.file(path).hexdigest == Digest::SHA256.file(master).hexdigest
  if same
    puts "SAME  #{t}"
  else
    FileUtils.cp(master, path)
    puts "SYNC  #{t}"
  end
end
