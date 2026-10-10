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
    <defs>
      <linearGradient id="boxLid" x1="0%" y1="0%" x2="0%" y2="100%">
        <stop offset="0%" stop-color="#006fb8"/>
        <stop offset="100%" stop-color="#015995"/>
      </linearGradient>
      <linearGradient id="boxBody" x1="0%" y1="0%" x2="0%" y2="100%">
        <stop offset="0%" stop-color="#36abf7"/>
        <stop offset="100%" stop-color="#0c8ee9"/>
      </linearGradient>
      <linearGradient id="badgeGrad" x1="0%" y1="0%" x2="0%" y2="100%">
        <stop offset="0%" stop-color="#22c55e"/>
        <stop offset="100%" stop-color="#16a34a"/>
      </linearGradient>
    </defs>
    <!-- Открытая крышка коробки -->
    <path d="M2.5 8 12 3.5 21.5 8 12 12.5z" fill="url(#boxLid)"/>
    <!-- Корпус коробки -->
    <rect x="4" y="9.5" width="16" height="10.5" rx="1.3" fill="url(#boxBody)"/>
    <!-- Белая лента -->
    <rect x="10.7" y="9.5" width="2.6" height="10.5" fill="#ffffff" opacity="0.95"/>
    <!-- Бейдж загрузки -->
    <circle cx="17" cy="16.5" r="4.4" fill="url(#badgeGrad)"/>
    <path d="M17 14.2v3.4M15.3 15.9 17 17.6l1.7-1.7" stroke="#ffffff" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round" fill="none"/>
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

def render_icon(target_size)
  scale = 4
  hires = target_size * scale
  buf = ImageBuffer.new(hires, hires)
  s = hires / 24.0

  hires.times do |y|
    ny = y / s
    hires.times do |x|
      nx = x / s

      # 1. Открытая крышка коробки (ромб)
      if in_poly?([[12.0, 3.5], [21.5, 8.0], [12.0, 12.5], [2.5, 8.0]], nx, ny)
        t = ((ny - 3.5) / 9.0).clamp(0.0, 1.0)
        # Градиент #006fb8 -> #015995
        buf.blend_pixel(x, y, (0 * (1 - t) + 1 * t).round, (111 * (1 - t) + 89 * t).round, (184 * (1 - t) + 149 * t).round, 255)
      end

      # 2. Корпус коробки (скруглённый прямоугольник)
      if in_rounded_rect?(nx, ny, 4.0, 9.5, 20.0, 20.0, 1.3)
        t = ((ny - 9.5) / 10.5).clamp(0.0, 1.0)
        # Градиент #36abf7 -> #0c8ee9
        buf.blend_pixel(x, y, (54 * (1 - t) + 12 * t).round, (171 * (1 - t) + 142 * t).round, (247 * (1 - t) + 233 * t).round, 255)
      end

      # 3. Белая лента (поверх корпуса)
      if nx >= 10.7 && nx <= 13.3 && ny >= 9.5 && ny <= 20.0
        buf.blend_pixel(x, y, 255, 255, 255, 242)
      end

      # 4. Круглый бейдж загрузки (зелёный градиент #22c55e -> #16a34a)
      dx = nx - 17.0
      dy = ny - 16.5
      if dx * dx + dy * dy <= 4.4 * 4.4
        is_shaft = dx.abs <= 0.75 && dy >= -2.4 && dy <= 0.7
        is_head  = dy > 0.7 && dy <= 2.7 && dx.abs <= (2.7 - dy) / 2.0 * 2.1
        if is_shaft || is_head
          buf.blend_pixel(x, y, 255, 255, 255, 255)
        else
          t = ((dy + 4.4) / 8.8).clamp(0.0, 1.0)
          buf.blend_pixel(x, y, (34 * (1 - t) + 22 * t).round, (197 * (1 - t) + 163 * t).round, (94 * (1 - t) + 74 * t).round, 255)
        end
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
