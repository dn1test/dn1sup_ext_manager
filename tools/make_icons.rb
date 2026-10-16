# frozen_string_literal: true
# =============================================================================
# tools/make_icons.rb — генерация иконки Extension Store для тулбара:
#   • векторный SVG: icons/store.svg (для современных версий SketchUp);
#   • растровые PNG: icons/store_16.png, store_24.png, store_32.png
#   (рендеринг чистым Ruby с 4x суперсэмплингом и антиалиасингом).
#
#   ruby tools/make_icons.rb
# =============================================================================

require 'zlib'
require 'fileutils'

SVG_CONTENT = <<~SVG
  <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="24" height="24">
    <!-- Задняя малая коробка -->
    <rect x="6.4" y="5.4" width="5.6" height="6.6" fill="#36abf7" stroke="#015995" stroke-width="1"/>
    <path d="M6.4 7.6h5.6" stroke="#015995" stroke-width="1"/>
    <!-- Передняя малая коробка -->
    <rect x="12" y="3.8" width="5.6" height="8.2" fill="#7cc7fb" stroke="#015995" stroke-width="1"/>
    <path d="M12 6h5.6" stroke="#015995" stroke-width="1"/>
    <!-- Большая коробка-лоток -->
    <path d="M3 11.5h18l-2 9H5z" fill="#0c8ee9" stroke="#015995" stroke-width="1.2" stroke-linejoin="round"/>
    <!-- Стрелка скачивания на борту -->
    <path d="M12 13.5v4M10.2 15.7l1.8 1.8 1.8-1.8" stroke="#ffffff" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" fill="none"/>
  </svg>
SVG

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

# -- Рендеринг иконки высокого разрешения (на сетке 24 x 24) ------------------
# Мотив: две малые коробки выглядывают из открытой большой, на борту —
# белая стрелка скачивания. Плоские заливки шкалы brand, без градиентов.

def dist_to_seg(px, py, ax, ay, bx, by)
  dx = bx - ax
  dy = by - ay
  len2 = dx * dx + dy * dy
  t = len2.zero? ? 0.0 : (((px - ax) * dx + (py - ay) * dy) / len2).clamp(0.0, 1.0)
  cx = ax + dx * t
  cy = ay + dy * t
  Math.sqrt((px - cx)**2 + (py - cy)**2)
end

def render_icon(target_size)
  scale = 4
  hires = target_size * scale
  buf = ImageBuffer.new(hires, hires)
  s = hires / 24.0

  navy = [1, 89, 149] # #015995 — обводки и крышки

  hires.times do |y|
    ny = y / s
    hires.times do |x|
      nx = x / s

      # 1. Задняя малая коробка (6.4,5.4)-(12.0,12.0), заливка #36abf7
      if nx >= 6.4 && nx <= 12.0 && ny >= 5.4 && ny <= 12.0
        buf.blend_pixel(x, y, 54, 171, 247, 255)
      end
      # Обводка 1px: полоса между внешним и внутренним прямоугольниками
      if nx >= 5.9 && nx <= 12.5 && ny >= 4.9 && ny <= 12.5 &&
         !(nx > 6.9 && nx < 11.5 && ny > 5.9 && ny < 11.5)
        buf.blend_pixel(x, y, *navy, 255)
      end
      # Линия крышки
      if nx >= 6.4 && nx <= 12.0 && (ny - 7.6).abs <= 0.5
        buf.blend_pixel(x, y, *navy, 255)
      end

      # 2. Передняя малая коробка (12.0,3.8)-(17.6,12.0), заливка #7cc7fb
      if nx >= 12.0 && nx <= 17.6 && ny >= 3.8 && ny <= 12.0
        buf.blend_pixel(x, y, 124, 199, 251, 255)
      end
      if nx >= 11.5 && nx <= 18.1 && ny >= 3.3 && ny <= 12.5 &&
         !(nx > 12.5 && nx < 17.1 && ny > 4.3 && ny < 11.5)
        buf.blend_pixel(x, y, *navy, 255)
      end
      if nx >= 12.0 && nx <= 17.6 && (ny - 6.0).abs <= 0.5
        buf.blend_pixel(x, y, *navy, 255)
      end

      # 3. Большая коробка-лоток, заливка #0c8ee9 (перекрывает низ малых)
      tray = [[3.0, 11.5], [21.0, 11.5], [19.0, 20.5], [5.0, 20.5]]
      if in_poly?(tray, nx, ny)
        buf.blend_pixel(x, y, 12, 142, 233, 255)
      end
      # Обводка лотка 1.2px: окрестность контура
      edges = [tray[0], tray[1], tray[2], tray[3]]
      near = edges.each_with_index.any? do |pt, i|
        dist_to_seg(nx, ny, pt[0], pt[1], edges[(i + 1) % 4][0], edges[(i + 1) % 4][1]) <= 0.6
      end
      buf.blend_pixel(x, y, *navy, 255) if near

      # 4. Белая стрелка скачивания на борту
      is_shaft = nx >= 11.1 && nx <= 12.9 && ny >= 13.5 && ny <= 17.5
      is_head = ny >= 15.7 && ny <= 17.5 && (nx - 12.0).abs <= (17.5 - ny)
      if is_shaft || is_head
        buf.blend_pixel(x, y, 255, 255, 255, 255)
      end
    end
  end

  buf.downsample(scale)
end

# -- Генерация файлов в папке icons ------------------------------------------

dest_dirs = [
  File.join(__dir__, '..', 'src', 'dn1sup_ext_manager', 'icons'),
  File.join(__dir__, '..', 'icons') # dev-копия в корне репозитория
]

dest_dirs.each do |out|
  FileUtils.mkdir_p(out)
  puts "Генерация иконок в #{out}:"

  # 1. SVG вектор
  svg_path = File.join(out, 'store.svg')
  File.write(svg_path, SVG_CONTENT, encoding: 'UTF-8')
  puts "  ✓ store.svg (Vector)"

  # 2. PNG размеры
  [16, 24, 32].each do |size|
    px = render_icon(size)
    write_png(File.join(out, "store_#{size}.png"), px, size, size)
  end
end

puts "\nГотово! Иконки успешно созданы."
