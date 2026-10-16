# frozen_string_literal: true
# =============================================================================
# tools/make_icons.rb — генерация плоских иконок в едином стиле «плитка»:
#   • знак менеджера: icons/store.svg + store_16/24/32.png
#     (PNG рендерится чистым Ruby с 4x суперсэмплингом и антиалиасингом);
#   • плитки всех расширений каталога: frontend/src/assets/products/<id>.svg
#     (GUI использует их вместо generic-значков lucide).
#
#   ruby tools/make_icons.rb
# =============================================================================

require 'zlib'
require 'fileutils'

# -- Единый стиль -------------------------------------------------------------
# Сплошные заливки без обводок: белый знак на цветном скруглённом квадрате
# (rx 5.5), сетка 24x24. Детали знака «вырезаются» цветом фона — иконка
# одинаково читается в светлой и тёмной теме и не «мылится» в PNG 16 px.

BRAND = '#0c8ee9' # фирменный синий плитки менеджера

# Цвет плитки кодирует назначение и повторяет палитру списка каталога
# (frontend/src/composables/useProductIcon.js).
PRODUCT_TILES = {
  'dn1sup_ext_manager'       => '#0c8ee9', # витрина каталога
  'dn1sup_time_project'      => '#0ea5e9', # учёт времени
  'dn1sup_create_project'    => '#10b981', # создание проекта
  'dn1sup_comp_add_view'     => '#f59e0b', # копии компонента и проекции
  'dn1sup_save_settings'     => '#64748b', # параметры SketchUp
  'dn1sup_export_3d'         => '#06b6d4', # экспорт glTF/GLB
  'dn1sup_autoselect_tag'    => '#8b5cf6', # автоназначение тегов
  'dn1sup_export_pdf2'       => '#f43f5e', # многостраничный PDF
  'dn1sup_sketchup_profiles' => '#6366f1'  # профили SketchUp
}.freeze

# Знаки плиток: лямбда принимает цвет фона для «вырезаемых» деталей.
GLYPHS = {}

GLYPHS['dn1sup_ext_manager'] = lambda do |c|
  <<~G
    <path d="M4 3.5h16l2 5.5H2z" fill="#ffffff"/>
    <rect x="5" y="10.5" width="14" height="10.5" fill="#ffffff"/>
    <rect x="6.8" y="11.8" width="2.8" height="2.4" fill="#{c}"/>
    <rect x="14.4" y="11.8" width="2.8" height="2.4" fill="#{c}"/>
    <rect x="10.2" y="15.4" width="3.6" height="5.6" fill="#{c}"/>
  G
end

GLYPHS['dn1sup_time_project'] = lambda do |c|
  <<~G
    <rect x="10.7" y="2" width="2.6" height="3.2" rx="1" fill="#ffffff"/>
    <circle cx="12" cy="14" r="7.3" fill="#ffffff"/>
    <path d="M12 14V9.6M12 14h3.4" stroke="#{c}" stroke-width="2" stroke-linecap="round" fill="none"/>
  G
end

GLYPHS['dn1sup_create_project'] = lambda do |c|
  <<~G
    <path d="M3 6.5a2 2 0 012-2h4.2l2 2H19a2 2 0 012 2V18a2 2 0 01-2 2H5a2 2 0 01-2-2z" fill="#ffffff"/>
    <rect x="11" y="11.2" width="2" height="6.4" fill="#{c}"/>
    <rect x="8.8" y="13.4" width="6.4" height="2" fill="#{c}"/>
  G
end

GLYPHS['dn1sup_comp_add_view'] = lambda do |c|
  <<~G
    <rect x="3.5" y="3.5" width="11" height="11" rx="2" fill="#ffffff" opacity="0.55"/>
    <rect x="9.5" y="9.5" width="11" height="11" rx="2" fill="#ffffff"/>
    <rect x="14" y="12" width="2" height="6" fill="#{c}"/>
    <rect x="12" y="14" width="6" height="2" fill="#{c}"/>
  G
end

GLYPHS['dn1sup_save_settings'] = lambda do |c|
  <<~G
    <rect x="3" y="5.2" width="18" height="2" rx="1" fill="#ffffff"/>
    <rect x="3" y="11" width="18" height="2" rx="1" fill="#ffffff"/>
    <rect x="3" y="16.8" width="18" height="2" rx="1" fill="#ffffff"/>
    <circle cx="15" cy="6.2" r="2.9" fill="#ffffff"/><circle cx="15" cy="6.2" r="1.3" fill="#{c}"/>
    <circle cx="8.5" cy="12" r="2.9" fill="#ffffff"/><circle cx="8.5" cy="12" r="1.3" fill="#{c}"/>
    <circle cx="16.5" cy="17.8" r="2.9" fill="#ffffff"/><circle cx="16.5" cy="17.8" r="1.3" fill="#{c}"/>
  G
end

GLYPHS['dn1sup_export_3d'] = lambda do |_c|
  <<~G
    <path d="M12 2.5l8.5 4.9L12 12.3 3.5 7.4z" fill="#ffffff"/>
    <path d="M3.5 7.4l8.5 4.9v9.2l-8.5-4.9z" fill="#ffffff" opacity="0.78"/>
    <path d="M20.5 7.4L12 12.3v9.2l8.5-4.9z" fill="#ffffff" opacity="0.58"/>
  G
end

GLYPHS['dn1sup_autoselect_tag'] = lambda do |c|
  <<~G
    <path d="M12.586 2.586A2 2 0 0011.172 2H4a2 2 0 00-2 2v7.172a2 2 0 00.586 1.414l8.704 8.704a2.426 2.426 0 003.42 0l6.586-6.586a2.426 2.426 0 000-3.42z" fill="#ffffff"/>
    <circle cx="7.5" cy="7.5" r="1.7" fill="#{c}"/>
    <path d="M16.2 13.2l.8 2 2 .8-2 .8-.8 2-.8-2-2-.8 2-.8z" fill="#{c}"/>
  G
end

GLYPHS['dn1sup_export_pdf2'] = lambda do |c|
  <<~G
    <path d="M6 2.5h7L18 7v13a1.5 1.5 0 01-1.5 1.5h-9A1.5 1.5 0 016 20z" fill="#ffffff"/>
    <path d="M13 2.5L18 7h-5z" fill="#{c}"/>
    <rect x="8.5" y="10.5" width="7" height="1.7" rx="0.85" fill="#{c}"/>
    <rect x="8.5" y="13.7" width="7" height="1.7" rx="0.85" fill="#{c}"/>
    <rect x="8.5" y="16.9" width="4.6" height="1.7" rx="0.85" fill="#{c}"/>
  G
end

GLYPHS['dn1sup_sketchup_profiles'] = lambda do |_c|
  <<~G
    <circle cx="12" cy="8" r="3.7" fill="#ffffff"/>
    <path d="M4.5 20.5c0-3.9 3.4-6.4 7.5-6.4s7.5 2.5 7.5 6.4z" fill="#ffffff"/>
    <circle cx="17.8" cy="7" r="3.4" fill="#ffffff" opacity="0.55"/>
    <path d="M13.6 20.5c.3-3.3 2.9-5.4 6-5.4.8 0 1.6.15 2.3.4v4.9z" fill="#ffffff" opacity="0.55"/>
  G
end

def tile_svg(color, glyph)
  <<~SVG
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="24" height="24">
      <rect width="24" height="24" rx="5.5" fill="#{color}"/>
    #{glyph.chomp}
    </svg>
  SVG
end

STORE_SVG = tile_svg(BRAND, GLYPHS['dn1sup_ext_manager'].call(BRAND))

# -- PNG сборщик -------------------------------------------------------------

def png_chunk(type, data)
  [data.bytesize].pack('N') + type + data + [Zlib.crc32(type + data)].pack('N')
end

def write_png(path, pixels, width, height)
  raw = pixels.map { |row| "\x00" + row.map { |px| px.pack('C4') }.join }.join
  png = "\x89PNG\r\n\x1a\n".b +
        png_chunk('IHDR', [width, height].pack('N2') + [8, 6, 0, 0, 0].pack('C5')) +
        png_chunk('IDAT', Zlib::Deflate.deflate(raw, Zlib::BEST_COMPRESSION)) +
        png_chunk('IEND', '')
  File.binwrite(path, png)
  puts "  ✓ #{File.basename(path)} (#{width}x#{height})"
end

# -- Канва с альфа-блендингом -------------------------------------------------

class ImageBuffer
  attr_reader :w, :h, :pixels

  def initialize(w, h)
    @w = w
    @h = h
    @pixels = Array.new(h) { Array.new(w) { [0, 0, 0, 0] } }
  end

  def blend_pixel(x, y, r, g, b, a)
    return if x < 0 || x >= @w || y < 0 || y >= @h || a <= 0

    cur = @pixels[y][x]
    sa = a / 255.0
    da = cur[3] / 255.0
    out_a = sa + da * (1.0 - sa)
    return if out_a.zero?

    out_r = ((r * sa + cur[0] * da * (1.0 - sa)) / out_a).round.clamp(0, 255)
    out_g = ((g * sa + cur[1] * da * (1.0 - sa)) / out_a).round.clamp(0, 255)
    out_b = ((b * sa + cur[2] * da * (1.0 - sa)) / out_a).round.clamp(0, 255)
    @pixels[y][x] = [out_r, out_g, out_b, (out_a * 255).round.clamp(0, 255)]
  end

  # Сглаженный спуск (4x бокс-фильтр) в результирующий буфер
  def downsample(scale = 4)
    target_w = @w / scale
    target_h = @h / scale
    out = Array.new(target_h) { Array.new(target_w) { [0, 0, 0, 0] } }

    target_h.times do |ty|
      target_w.times do |tx|
        sum_r = 0.0
        sum_g = 0.0
        sum_b = 0.0
        sum_a = 0.0

        scale.times do |sy|
          scale.times do |sx|
            px = @pixels[ty * scale + sy][tx * scale + sx]
            a = px[3] / 255.0
            sum_r += px[0] * a
            sum_g += px[1] * a
            sum_b += px[2] * a
            sum_a += a
          end
        end

        count = (scale * scale).to_f
        avg_a = sum_a / count
        if avg_a > 0.001
          avg_r = (sum_r / sum_a).round.clamp(0, 255)
          avg_g = (sum_g / sum_a).round.clamp(0, 255)
          avg_b = (sum_b / sum_a).round.clamp(0, 255)
          out[ty][tx] = [avg_r, avg_g, avg_b, (avg_a * 255).round.clamp(0, 255)]
        end
      end
    end
    out
  end
end

# -- Геометрические помощники ------------------------------------------------

def in_poly?(pts, x, y)
  inside = false
  j = pts.length - 1
  pts.length.times do |i|
    xi, yi = pts[i]
    xj, yj = pts[j]
    if (yi > y) != (yj > y) && x < (xj - xi) * (y - yi) / (yj - yi.to_f) + xi
      inside = !inside
    end
    j = i
  end
  inside
end

def in_rounded_rect?(x, y, x0, y0, x1, y1, r)
  return false if x < x0 || x > x1 || y < y0 || y > y1

  cx = x < x0 + r ? x0 + r : (x > x1 - r ? x1 - r : x)
  cy = y < y0 + r ? y0 + r : (y > y1 - r ? y1 - r : y)
  (x - cx)**2 + (y - cy)**2 <= r * r
end

# -- Рендеринг иконки менеджера высокого разрешения (сетка 24 x 24) -----------
# Мотив: витрина магазина — белый навес-козырёк, корпус с дверью и двумя
# окнами на синей скруглённой плитке brand. Плоские заливки, без градиентов.

def render_icon(target_size)
  scale = 4
  hires = target_size * scale
  buf = ImageBuffer.new(hires, hires)
  s = hires / 24.0

  brand = [12, 142, 233] # #0c8ee9 — фон плитки и «вырезы» деталей
  white = [255, 255, 255]

  # Навес-козырёк витрины (трапеция со свесом за корпус)
  awning = [[4.0, 3.5], [20.0, 3.5], [22.0, 9.0], [2.0, 9.0]]

  hires.times do |y|
    ny = y / s
    hires.times do |x|
      nx = x / s

      color = nil
      # 1. Фон — скруглённый квадрат brand на всю канву
      color = brand if in_rounded_rect?(nx, ny, 0.0, 0.0, 24.0, 24.0, 5.5)
      # 2. Белый знак: козырёк и корпус витрины
      color = white if in_poly?(awning, nx, ny)
      color = white if nx >= 5.0 && nx <= 19.0 && ny >= 10.5 && ny <= 21.0
      # 3. Детали цветом фона: два окна и дверь (с зазорами для 16 px)
      color = brand if nx >= 6.8 && nx <= 9.6 && ny >= 11.8 && ny <= 14.2
      color = brand if nx >= 14.4 && nx <= 17.2 && ny >= 11.8 && ny <= 14.2
      color = brand if nx >= 10.2 && nx <= 13.8 && ny >= 15.4 && ny <= 21.0

      buf.blend_pixel(x, y, *color, 255) if color
    end
  end

  buf.downsample(scale)
end

# -- Генерация файлов ---------------------------------------------------------

# 1. Знак менеджера: SVG + PNG в src-копию (для .rbz) и dev-копию в корне
dest_dirs = [
  File.join(__dir__, '..', 'src', 'dn1sup_ext_manager', 'icons'),
  File.join(__dir__, '..', 'icons') # dev-копия в корне репозитория
]

dest_dirs.each do |out|
  FileUtils.mkdir_p(out)
  puts "Генерация иконок в #{out}:"

  svg_path = File.join(out, 'store.svg')
  File.write(svg_path, STORE_SVG, encoding: 'UTF-8')
  puts '  ✓ store.svg (Vector)'

  [16, 24, 32].each do |size|
    px = render_icon(size)
    write_png(File.join(out, "store_#{size}.png"), px, size, size)
  end
end

# 2. Плитки каталога для GUI (импортируются через Vite)
products_dir = File.join(__dir__, '..', 'frontend', 'src', 'assets', 'products')
FileUtils.mkdir_p(products_dir)
puts "Генерация плиток каталога в #{products_dir}:"
PRODUCT_TILES.each do |id, color|
  path = File.join(products_dir, "#{id}.svg")
  File.write(path, tile_svg(color, GLYPHS.fetch(id).call(color)), encoding: 'UTF-8')
  puts "  ✓ #{id}.svg"
end

puts "\nГотово! Иконки успешно созданы."
