# frozen_string_literal: true
# =============================================================================
# tools/make_icons.rb — генерация всех иконок DN1Sup из единого описания знаков.
#
# Архитектура: каждый знак — список примитивов (ops), из которого собираются
# сразу все форматы:
#   • плитки каталога GUI (стиль «Флэт»): белый знак на цветном скруглённом
#     квадрате rx 5.5, сетка 24×24; знак занимает ~75% плитки («воздух»),
#     детали вырезаются цветом фона → frontend/src/assets/products/<id>.svg;
#   • знаки тулбара SketchUp: только знак, фон прозрачный, вырезы — настоящие
#     дырки (SVG-маска; PNG рендерится альфа-каналом с 4x суперсэмплингом):
#       - менеджер: icons/store.svg + store_16/24/32.png (src-копия для .rbz
#         и dev-копия в корне);
#       - все расширения: источник в icons/products/ — <id>.svg и
#         <id>_16/24/32.png; у Export PDF 2 — дополнительно три знака его
#         тулбар-команд (dn1sup_export_pdf2__<fn>.*).
#
#   ruby tools/make_icons.rb
# =============================================================================

require 'zlib'
require 'fileutils'

BRAND = '#0c8ee9' # фирменный синий знака менеджера

# Цвет кодирует назначение расширения (совпадает с плитками каталога).
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

# -- Примитивы знака -----------------------------------------------------------
#   [:rect,   x, y, w, h, rx, role, opacity]
#   [:circle, cx, cy, r, role, opacity]
#   [:poly,   [[x, y], ...], role, opacity]
#   [:line,   x1, y1, x2, y2, width, role]      штрих со скруглёнными концами
# role :sign — заливка знаком (белый на плитке / цвет расширения в тулбаре),
# role :hole — вырез: на плитке цветом фона, в знаке тулбара — прозрачность.

def cube_ops(cx, cy, a)
  t  = [cx, cy - 1.118 * a]
  r  = [cx + a, cy - 0.541 * a]
  b  = [cx, cy + 0.035 * a]
  l  = [cx - a, cy - 0.541 * a]
  bl = [cx - a, cy + 0.541 * a]
  o  = [cx, cy + 1.118 * a]
  br = [cx + a, cy + 0.541 * a]
  [[:poly, [t, r, b, l], :sign, 1.0],
   [:poly, [l, b, o, bl], :sign, 0.78],
   [:poly, [b, r, br, o], :sign, 0.58]]
end

def gear_ops(cx, cy, ro, ri, teeth)
  tw = 2 * Math::PI / teeth
  pts = []
  teeth.times do |i|
    a = i * tw - Math::PI / 2
    pts << [cx + ri * Math.cos(a),                 cy + ri * Math.sin(a)]
    pts << [cx + ro * Math.cos(a + tw * 0.18),     cy + ro * Math.sin(a + tw * 0.18)]
    pts << [cx + ro * Math.cos(a + tw * 0.5),      cy + ro * Math.sin(a + tw * 0.5)]
    pts << [cx + ri * Math.cos(a + tw * 0.68),     cy + ri * Math.sin(a + tw * 0.68)]
  end
  [[:poly, pts, :sign, 1.0]]
end

PDF2_PAGE = [
  [:poly, [[3, 3.2], [10.4, 3.2], [14.6, 7.4], [14.6, 20.5], [13.1, 22], [4.5, 22], [3, 20.5]], :sign, 1.0],
  [:poly, [[10.4, 3.2], [14.6, 7.4], [10.4, 7.4]], :hole, 1.0]
].freeze

GLYPHS = {
  # Витрина: козырёк со свесом, корпус, два окна и дверь.
  'dn1sup_ext_manager' => [
    [:poly, [[4, 3.5], [20, 3.5], [22, 9], [2, 9]], :sign, 1.0],
    [:rect, 5, 10.5, 14, 10.5, 0, :sign, 1.0],
    [:rect, 6.8, 11.8, 2.8, 2.4, 0, :hole, 1.0],
    [:rect, 14.4, 11.8, 2.8, 2.4, 0, :hole, 1.0],
    [:rect, 10.2, 15.4, 3.6, 5.6, 0, :hole, 1.0]
  ],
  # Часы: корпус с кнопкой, стрелки вырезаны.
  'dn1sup_time_project' => [
    [:rect, 10.7, 2, 2.6, 3.2, 1, :sign, 1.0],
    [:circle, 12, 14, 7.3, :sign, 1.0],
    [:line, 12, 14, 12, 9.6, 2, :hole],
    [:line, 12, 14, 15.4, 14, 2, :hole]
  ],
  # Папка проекта с плюсом.
  'dn1sup_create_project' => [
    [:rect, 3, 6.5, 18, 13.5, 2, :sign, 1.0],
    [:poly, [[3, 6.5], [3, 5.9], [3.6, 5.1], [4.4, 4.5], [9.2, 4.5], [11.2, 6.5]], :sign, 1.0],
    [:rect, 11, 11.2, 2, 6.4, 0, :hole, 1.0],
    [:rect, 8.8, 13.4, 6.4, 2, 0, :hole, 1.0]
  ],
  # Копии: плитка-призрак и плитка с плюсом.
  'dn1sup_comp_add_view' => [
    [:rect, 3.5, 3.5, 11, 11, 2, :sign, 0.55],
    [:rect, 9.5, 9.5, 11, 11, 2, :sign, 1.0],
    [:rect, 14, 12, 2, 6, 0, :hole, 1.0],
    [:rect, 12, 14, 6, 2, 0, :hole, 1.0]
  ],
  # Ползунки настроек.
  'dn1sup_save_settings' => [
    [:rect, 3, 5.2, 18, 2, 1, :sign, 1.0],
    [:rect, 3, 11, 18, 2, 1, :sign, 1.0],
    [:rect, 3, 16.8, 18, 2, 1, :sign, 1.0],
    [:circle, 15, 6.2, 2.9, :sign, 1.0],
    [:circle, 15, 6.2, 1.3, :hole, 1.0],
    [:circle, 8.5, 12, 2.9, :sign, 1.0],
    [:circle, 8.5, 12, 1.3, :hole, 1.0],
    [:circle, 16.5, 17.8, 2.9, :sign, 1.0],
    [:circle, 16.5, 17.8, 1.3, :hole, 1.0]
  ],
  # Изометрический куб с гранями разной плотности.
  'dn1sup_export_3d' => cube_ops(12, 12, 8.5),
  # Бирка с отверстием и искрой «авто».
  'dn1sup_autoselect_tag' => [
    [:poly, [[12.586, 2.586], [11.172, 2], [4, 2], [2, 4], [2, 11.172], [2.586, 12.586],
            [11.29, 21.294], [14.71, 21.294], [21.296, 14.708], [21.296, 11.288]], :sign, 1.0],
    [:circle, 7.5, 7.5, 1.7, :hole, 1.0],
    [:poly, [[16.2, 13.2], [17, 15.2], [19, 16], [17, 16.8], [16.2, 18.8], [15.4, 16.8], [13.4, 16], [15.4, 15.2]], :hole, 1.0]
  ],
  # Документ с загнутым уголком и строками.
  'dn1sup_export_pdf2' => [
    [:poly, [[6, 2.5], [13, 2.5], [18, 7], [18, 20.5], [16.5, 22], [7.5, 22], [6, 20.5]], :sign, 1.0],
    [:poly, [[13, 2.5], [18, 7], [13, 7]], :hole, 1.0],
    [:rect, 8.5, 10.5, 7, 1.7, 0.85, :hole, 1.0],
    [:rect, 8.5, 13.7, 7, 1.7, 0.85, :hole, 1.0],
    [:rect, 8.5, 16.9, 4.6, 1.7, 0.85, :hole, 1.0]
  ],
  # Профиль и полупрозрачный второй профиль (призрак рисуется первым,
  # чтобы плотный силуэт перекрывал его — без светлой точки на стыке голов).
  'dn1sup_sketchup_profiles' => [
    [:circle, 17.8, 7, 3.4, :sign, 0.55],
    [:poly, [[13.6, 20.5], [14.0, 17.5], [15.8, 15.7], [18.1, 15.1], [20.3, 15.4], [21.9, 15.9], [21.9, 20.5]], :sign, 0.55],
    [:circle, 12, 8, 3.7, :sign, 1.0],
    [:poly, [[4.5, 20.5], [4.9, 17.6], [6.5, 15.3], [9.1, 14.1], [12, 14.1], [14.9, 14.1],
            [17.5, 15.3], [19.1, 17.6], [19.5, 20.5]], :sign, 1.0]
  ]
}.freeze

# Export PDF 2 — три тулбар-команды (семейство знака «документ»).
GLYPHS_PDF2 = {
  'export_dialog' => PDF2_PAGE + [
    [:rect, 5.3, 10.3, 5.2, 1.5, 0.75, :hole, 1.0],
    [:rect, 5.3, 13.1, 5.2, 1.5, 0.75, :hole, 1.0]
  ] + gear_ops(17.4, 17.2, 5.2, 4.35, 8) + [
    [:circle, 17.4, 17.2, 2.1, :hole, 1.0]
  ],
  'quick_export' => PDF2_PAGE + [
    [:rect, 5.3, 10.3, 5.2, 1.5, 0.75, :hole, 1.0],
    [:rect, 5.3, 13.1, 5.2, 1.5, 0.75, :hole, 1.0],
    [:poly, [[19.4, 6.6], [15.7, 12.7], [18.1, 12.7], [16.5, 19.8], [22.3, 12.7], [19.5, 12.7], [21.9, 6.6]], :sign, 1.0]
  ],
  'frame_overlay' => [
    [:rect, 3, 3, 2.2, 6, 0, :sign, 1.0], [:rect, 3, 3, 6, 2.2, 0, :sign, 1.0],
    [:rect, 18.8, 3, 2.2, 6, 0, :sign, 1.0], [:rect, 15, 3, 6, 2.2, 0, :sign, 1.0],
    [:rect, 3, 15, 2.2, 6, 0, :sign, 1.0], [:rect, 3, 18.8, 6, 2.2, 0, :sign, 1.0],
    [:rect, 18.8, 15, 2.2, 6, 0, :sign, 1.0], [:rect, 15, 18.8, 6, 2.2, 0, :sign, 1.0],
    [:poly, [[8.6, 6.9], [12.5, 6.9], [15.4, 9.8], [15.4, 16.8], [14.3, 17.9], [9.7, 17.9], [8.6, 16.8]], :sign, 1.0],
    [:poly, [[12.5, 6.9], [15.4, 9.8], [12.5, 9.8]], :hole, 1.0]
  ]
}.freeze

# -- SVG ------------------------------------------------------------------------

def fn(v)
  s = format('%.2f', v)
  s = s.sub(/\.00$/, '').sub(/(\.\d)0$/, '\1')
  s
end

def op_role(op)
  op[0] == :line ? op[6] : op[-2]
end

def op_opacity(op)
  return 1.0 if op[0] == :line

  op[-1]
end

def ops_svg(ops, sign_fill, hole_fill)
  ops.map do |op|
    fill = op_role(op) == :sign ? sign_fill : hole_fill
    extra = op_opacity(op) < 1.0 ? format(' opacity="%.2f"', op_opacity(op)).sub(/0+$/, '').sub(/\.$/, '') : ''
    case op[0]
    when :rect
      rxa = op[5].to_f > 0 ? " rx=\"#{fn(op[5])}\"" : ''
      "<rect x=\"#{fn(op[1])}\" y=\"#{fn(op[2])}\" width=\"#{fn(op[3])}\" height=\"#{fn(op[4])}\"#{rxa} fill=\"#{fill}\"#{extra}/>"
    when :circle
      "<circle cx=\"#{fn(op[1])}\" cy=\"#{fn(op[2])}\" r=\"#{fn(op[3])}\" fill=\"#{fill}\"#{extra}/>"
    when :poly
      d = 'M' + op[1].map { |x, y| "#{fn(x)} #{fn(y)}" }.join('L') + 'Z'
      "<path d=\"#{d}\" fill=\"#{fill}\"#{extra}/>"
    when :line
      "<line x1=\"#{fn(op[1])}\" y1=\"#{fn(op[2])}\" x2=\"#{fn(op[3])}\" y2=\"#{fn(op[4])}\"" \
        " stroke=\"#{fill}\" stroke-width=\"#{fn(op[5])}\" stroke-linecap=\"round\"#{extra}/>"
    end
  end.join
end

TILE_SCALE = 0.75 # знак занимает ~75% плитки, остальное — «воздух» фона

# Плитка каталога GUI: цветной квадрат + белый знак с полем вокруг.
def tile_svg(color, ops)
  off = fn(12 * (1 - TILE_SCALE))
  <<~SVG
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="24" height="24">
    <rect width="24" height="24" rx="5.5" fill="#{color}"/>
    <g transform="translate(#{off} #{off}) scale(#{TILE_SCALE})">#{ops_svg(ops, '#ffffff', color)}</g>
    </svg>
  SVG
end

# Знак тулбара: без плитки, вырезы — настоящая прозрачность (маска).
def sign_svg(color, ops)
  <<~SVG
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="24" height="24">
    <defs>
    <mask id="g" maskUnits="userSpaceOnUse" x="0" y="0" width="24" height="24">
    <rect width="24" height="24" fill="#000000"/>
    #{ops_svg(ops, '#ffffff', '#000000')}
    </mask>
    </defs>
    <rect width="24" height="24" fill="#{color}" mask="url(#g)"/>
    </svg>
  SVG
end

# -- PNG сборщик ----------------------------------------------------------------

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

# -- Геометрия ------------------------------------------------------------------

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

def in_capsule?(x, y, x1, y1, x2, y2, w)
  dx = x2 - x1
  dy = y2 - y1
  len2 = dx * dx + dy * dy
  t = len2.zero? ? 0.0 : ((x - x1) * dx + (y - y1) * dy) / len2
  t = t.clamp(0.0, 1.0)
  px = x1 + t * dx
  py = y1 + t * dy
  (x - px)**2 + (y - py)**2 <= (w / 2.0)**2
end

def covered?(op, x, y)
  case op[0]
  when :rect
    x0, y0, w, h = op[1], op[2], op[3], op[4]
    rr = op[5].to_f
    return false if x < x0 || x > x0 + w || y < y0 || y > y0 + h
    rr > 0 ? in_rounded_rect?(x, y, x0, y0, x0 + w, y0 + h, rr) : true
  when :circle
    (x - op[1])**2 + (y - op[2])**2 <= op[3]**2
  when :poly
    in_poly?(op[1], x, y)
  when :line
    in_capsule?(x, y, op[1], op[2], op[3], op[4], op[5])
  end
end

# Растеризация знака тулбара: цвет расширения + настоящая альфа (4x сглаживание).
def render_sign(ops, rgb, target)
  scale = 4
  hires = target * scale
  s = hires / 24.0
  r, g, b = rgb
  cov = Array.new(hires) { Array.new(hires, 0.0) }

  hires.times do |py|
    ny = py / s
    hires.times do |px|
      nx = px / s
      a = 0.0
      ops.each do |op|
        next unless covered?(op, nx, ny)

        if op_role(op) == :sign
          o = op_opacity(op)
          a += o * (1 - a)
        else
          a *= (1.0 - op_opacity(op))
        end
      end
      cov[py][px] = a
    end
  end

  Array.new(target) do |ty|
    Array.new(target) do |tx|
      sum = 0.0
      scale.times { |sy| scale.times { |sx| sum += cov[ty * scale + sy][tx * scale + sx] } }
      [r, g, b, (sum / (scale * scale) * 255).round.clamp(0, 255)]
    end
  end
end

def hex_rgb(hex)
  n = Integer(hex[1..], 16)
  [(n >> 16) & 255, (n >> 8) & 255, n & 255]
end

# -- Генерация файлов -----------------------------------------------------------

root = File.expand_path('..', __dir__)

# 1. Менеджер: знак тулбара (SVG + PNG 16/24/32) в src-копию для .rbz и dev-копию
manager_ops = GLYPHS.fetch('dn1sup_ext_manager')
[
  File.join(root, 'src', 'dn1sup_ext_manager', 'icons'),
  File.join(root, 'icons')
].each do |out|
  FileUtils.mkdir_p(out)
  puts "Знак менеджера в #{out}:"
  File.write(File.join(out, 'store.svg'), sign_svg(BRAND, manager_ops), encoding: 'UTF-8')
  puts '  ✓ store.svg (Vector, прозрачный фон)'
  [16, 24, 32].each do |size|
    px = render_sign(manager_ops, hex_rgb(BRAND), size)
    write_png(File.join(out, "store_#{size}.png"), px, size, size)
  end
end

# 2. Плитки каталога GUI (Флэт, знак ~75% плитки)
products_dir = File.join(root, 'frontend', 'src', 'assets', 'products')
FileUtils.mkdir_p(products_dir)
puts "Плитки каталога GUI в #{products_dir}:"
PRODUCT_TILES.each do |id, color|
  File.write(File.join(products_dir, "#{id}.svg"), tile_svg(color, GLYPHS.fetch(id)), encoding: 'UTF-8')
  puts "  ✓ #{id}.svg"
end

# 3. Знаки тулбаров всех расширений: источник в icons/products/
signs_dir = File.join(root, 'icons', 'products')
FileUtils.mkdir_p(signs_dir)
puts "Знаки тулбаров в #{signs_dir}:"
PRODUCT_TILES.each do |id, color|
  ops = GLYPHS.fetch(id)
  rgb = hex_rgb(color)
  File.write(File.join(signs_dir, "#{id}.svg"), sign_svg(color, ops), encoding: 'UTF-8')
  [16, 24, 32].each do |size|
    px = render_sign(ops, rgb, size)
    write_png(File.join(signs_dir, "#{id}_#{size}.png"), px, size, size)
  end
  puts "  ✓ #{id}.svg + PNG 16/24/32"
end
puts 'Тулбар-команды Export PDF 2:'
GLYPHS_PDF2.each do |fn_name, ops|
  rgb = hex_rgb(PRODUCT_TILES.fetch('dn1sup_export_pdf2'))
  File.write(File.join(signs_dir, "dn1sup_export_pdf2__#{fn_name}.svg"), sign_svg(PRODUCT_TILES.fetch('dn1sup_export_pdf2'), ops), encoding: 'UTF-8')
  [16, 24, 32].each do |size|
    px = render_sign(ops, rgb, size)
    write_png(File.join(signs_dir, "dn1sup_export_pdf2__#{fn_name}_#{size}.png"), px, size, size)
  end
  puts "  ✓ dn1sup_export_pdf2__#{fn_name}.svg + PNG 16/24/32"
end

puts "\nГотово! Иконки успешно созданы."
