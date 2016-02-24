
--BMP file load/save.
--Written by Cosmin Apreutesei. Public Domain.

--TODO: RLE4
--TOOD: saving BI_RGB (rgb555, bgr8, bgrx8, bgrx16), and BI_BITFIELDS bgra8
--TODO: saving demo
--TODO: docs

if not ... then require'bmp_test'; return end

local ffi = require'ffi'
local bit = require'bit'
local bitmap = require'bitmap'
local glue = require'glue'

local M = {}

--BITMAPFILEHEADER
local file_header = ffi.typeof[[struct __attribute__((__packed__)) {
	char     magic[2]; // 'BM'
	uint32_t size;
	uint16_t reserved1;
	uint16_t reserved2;
	uint32_t image_offset;
	uint32_t header_size;
}]]

--BITMAPCOREHEADER, Windows 2.0 or later
local core_header = ffi.typeof[[struct __attribute__((__packed__)) {
	// BITMAPCOREHEADER
	uint16_t w;
	uint16_t h;
	uint16_t planes;       // 1
	uint16_t bpp;          // 1, 4, 8, 24
}]]

--BITMAPINFOHEADER, Windows NT, 3.1x or later
local info_header = ffi.typeof[[struct __attribute__((__packed__)) {
	int32_t  w;
	int32_t  h;
	uint16_t planes;       // 1
	uint16_t bpp;          // 0, 1, 4, 8, 16, 24, 32; 64 (GDI+)
	uint32_t compression;  // 0-6
	uint32_t image_size;   // 0 for BI_RGB
	uint32_t dpi_v;
	uint32_t dpi_h;
	uint32_t palette_colors; // 0 = 2^n
	uint32_t palette_colors_important; // ignored
}]]

--BITMAPV2INFOHEADER, undocumented, Adobe Photoshop
local v2_header = ffi.typeof([[struct __attribute__((__packed__)) {
	$;
	uint32_t mask_r;
	uint32_t mask_g;
	uint32_t mask_b;
}]], info_header)

--BITMAPV3INFOHEADER, undocumented, Adobe Photoshop
local v3_header = ffi.typeof([[struct __attribute__((__packed__)) {
	$;
	uint32_t mask_a;
}]], v2_header)

--BITMAPV4HEADER, Windows NT 4.0, 95 or later
local v4_header = ffi.typeof([[struct __attribute__((__packed__)) {
	$;
	uint32_t cs_type;
	struct { int32_t rx, ry, rz, gx, gy, gz, bx, by, bz; } endpoints;
	uint32_t gamma_r;
	uint32_t gamma_g;
	uint32_t gamma_b;
}]], v3_header)

--BITMAPV5HEADER, Windows NT 5.0, 98 or later
local v5_header = ffi.typeof([[struct __attribute__((__packed__)) {
	$;
	uint32_t intent;
	uint32_t profile_data;
	uint32_t profile_size;
	uint32_t reserved;
}]], v4_header)

local rgb_triple = ffi.typeof[[struct __attribute__((__packed__)) {
	uint8_t b;
	uint8_t g;
	uint8_t r;
}]]

local rgb_quad = ffi.typeof([[struct __attribute__((__packed__)) {
	$;
	uint8_t a;
}]], rgb_triple)

local compressions = {[0] = 'rgb', 'rle8', 'rle4', 'bitfields',
	'jpeg', 'png', 'alphabitfields'}

local valid_bpps = {
	rgb = glue.index{1, 2, 4, 8, 16, 24, 32, 64},
	rle4 = glue.index{4},
	rle8 = glue.index{8},
	bitfields = glue.index{16, 32},
	alphabitfields = glue.index{16, 32},
	jpeg = glue.index{0},
	png = glue.index{0},
}

function M.open(read_bytes)

	--wrap the reader so we can count the bytes read
	local bytes_read = 0
	local function read(buf, sz)
		local sz = sz or ffi.sizeof(buf)
		read_bytes(buf, sz)
		bytes_read = bytes_read + sz
		return buf
	end

	--load the file header and validate it
	local fh = read(file_header())
	assert(ffi.string(fh.magic, 2) == 'BM')

	--load the DIB header
	local z = fh.header_size - 4
	local core --the ancient core header is more restricted
	local alpha_mask = true --bitfields can contain a mask for alpha or not
	local quad_pal = true --palette entries are quads except for core header
	local h
	if z == ffi.sizeof(core_header) then
		core = true
		quad_pal = false
		h = read(core_header())
	elseif z == ffi.sizeof(info_header) then
		alpha_mask = false --...unless comp == 'alphabitfields', see below
		h = read(info_header())
	elseif z == ffi.sizeof(v2_header) then
		alpha_mask = false
		h = read(v2_header())
	elseif z == ffi.sizeof(v3_header) then
		h = read(v3_header())
	elseif z == ffi.sizeof(v4_header) then
		h = read(v4_header())
	elseif z == ffi.sizeof(v5_header) then
		h = read(v5_header())
	elseif z == 64 + 4 then
		error'OS22XBITMAPHEADER is not supported'
	else
		error('invalid info header size '..(z+4))
	end

	--validate it and extract info from it
	assert(h.planes == 1, 'invalid number of planes')
	local comp = core and 0 or h.compression
	local comp = assert(compressions[comp], 'invalid compression type')
	alpha_mask = alpha_mask or comp == 'alphabitfields' --Windows CE
	local bpp = h.bpp
	assert(valid_bpps[comp][bpp], 'invalid bpp')
	local rle = comp:find'^rle'
	local bitfields = comp:find'bitfields$'
	local palettized = bpp >=1 and bpp <= 8
	local width = h.w
	local height = math.abs(h.h)
	local bottom_up = h.h > 0
	assert(width >= 1, 'invalid width')
	assert(height >= 1, 'invalid height')

	--load the channel masks for bitfield bitmaps
	local bitmasks, has_alpha
	if bitfields then
		bitmasks = ffi.new('uint32_t[?]', 4)
		read(bitmasks, (alpha_mask and 4 or 3) * 4)
		has_alpha = bitmasks[3] > 0
	end

	--make a palette loader and indexer
	local pal_size = fh.image_offset - bytes_read
	assert(pal_size >= 0, 'invalid image offset')
	local load_pal
	local function noop() end
	local function skip_pal()
		read(nil, pal_size) --null-read to pixel data
		load_pal = noop
	end
	load_pal = skip_pal
	local pal_count = 0
	local pal
	if palettized then
		local pal_entry_ct = quad_pal and rgb_quad or rgb_triple
		local pal_ct = ffi.typeof('$[?]', pal_entry_ct)
		pal_count = math.floor(pal_size / ffi.sizeof(pal_entry_ct))
		pal_count = math.min(pal_count, 2^bpp)
		if pal_count > 0 then
			function load_pal()
				pal = read(pal_ct(pal_count))
				read(nil, pal_size - ffi.sizeof(pal)) --null-read to pixel data
				load_pal = noop
			end
		end
	end
	local function pal_entry(i)
		load_pal()
		assert(i < pal_count, 'palette index out of range')
		return pal[i].r, pal[i].g, pal[i].b, 0xff
	end

	--make a progressive (row-by-row) loader
	local load
	if comp == 'jpeg' then
		error'jpeg not supported'
	elseif comp == 'png' then
		error'png not supported'
	else
		function load(_, dst_bmp, dst_x, dst_y)

			--decide on the row bitmap format and if needed make a pixel converter
			local format, convert_pixel, src_colorspace, dst_colorspace
			if bitfields then --packed, standard or custom format

				--compute the shift distance and the number of bits for each mask
				local function mask_shr_bits(mask)
					if mask == 0 then
						return 0, 0
					end
					local shr = 0
					while bit.band(mask, 1) == 0 do --lowest bit not reached yet
						mask = bit.rshift(mask, 1)
						shr = shr + 1
					end
					local bits = 0
					while mask > 0 do --highest bit not cleared yet
						mask = bit.rshift(mask, 1)
						bits = bits + 1
					end
					return shr, bits
				end

				--build a standard format name based on the bitfield masks
				local t = {} --{shr1, ...}
				local tc = {} --{shr -> color}
				local tb = {} --{shr -> bits}
				for ci, color in ipairs{'r', 'g', 'b', 'a'} do
					local shr, bits = mask_shr_bits(bitmasks[ci-1])
					if bits > 0 then
						t[#t+1] = shr
						tc[shr] = color
						tb[shr] = bits
					end
				end
				table.sort(t, function(a, b) return a > b end)
				local tc2, tb2 = {}, {}
				for i,shr in ipairs(t) do
					tc2[i] = tc[shr]
					tb2[i] = tb[shr]
				end
				format = table.concat(tc2)..table.concat(tb2)
				format = format:gsub('([^%d])8?888$', '%18')

				--make a custom pixel converter if the bitfields do not represent
				--a standard format implemented in the `bitmap` module.
				if not bitmap.formats[format] then
					format = 'raw'..bpp
					dst_colorspace = 'rgba8'
					local band, shr = bit.band, bit.rshift
					local r_and = bitmasks[0]
					local r_shr = mask_shr_bits(r_and)
					local g_and = bitmasks[1]
					local g_shr = mask_shr_bits(g_and)
					local b_and = bitmasks[2]
					local b_shr = mask_shr_bits(b_and)
					local a_and = bitmasks[3]
					local a_shr = mask_shr_bits(a_and)
					function convert_pixel(x)
						return
							shr(band(x, r_and), r_shr),
							shr(band(x, g_and), g_shr),
							shr(band(x, b_and), b_shr),
							has_alpha and shr(band(x, a_and), a_shr) or 0xff
					end
				end

			elseif bpp <= 8 then --palettized, using custom converter

				format = 'g'..bpp --using gray<1,2,4,8> as the base format
				dst_colorspace = 'rgba8'
				local shr = bit.rshift
				if bpp == 1 then
					function convert_pixel(g8)
						return pal_entry(shr(g8, 7))
					end
				elseif bpp == 2 then
					function convert_pixel(g8)
						return pal_entry(shr(g8, 6))
					end
				elseif bpp == 4 then
					function convert_pixel(g8)
						return pal_entry(shr(g8, 4))
					end
				elseif bpp == 8 then
					convert_pixel = pal_entry
				else
					assert(false)
				end

			else --packed, standard format

				local formats = {
					[16] = 'rgb0555',
					[24] = 'bgr8',
					[32] = 'bgrx8',
					[64] = 'bgrx16',
				}
				format = assert(formats[bpp])

			end

			--allocate a single-row bitmap in the original format.
			local row_bmp = bitmap.new(width, 1, format, bottom_up, true)

			--check bitmap stride against the known stride formula.
			local src_stride = math.floor((bpp * width + 31) / 32) * 4
			assert(row_bmp.stride == src_stride)

			--row reader: either straight read or RLE decode
			local read_row
			if rle then
				assert(bpp == 8, 'RLE4 not supported') --TODO
				local rle_buf = ffi.new'uint8_t[2]'
				local j = 0
				function read_row()
					local i = 0
					while true do
						read(rle_buf, 2)
						local n = rle_buf[0]
						local k = rle_buf[1]
						if n == 0 then --escape
							if k == 0 then --eol
								assert(i == width, 'RLE EOL too soon')
								j = j + 1
								break
							elseif k == 1 then --eof
								assert(j == height-1, 'RLE EOF too soon')
								break
							elseif k == 2 then --delta
								read(rle_buf, 2)
								local x = rle_buf[0]
								local y = rle_buf[1]
								--we can't use a row-by-row loader with this code
								error'RLE delta not supported'
							else --absolute mode: k = number of pixels to read
								assert(i + k <= width, 'RLE overflow')
								read(row_bmp.data + i, k)
								--read the word-align padding
								local k2 = bit.band(k + 1, bit.bnot(1)) - k
								if k2 > 0 then
									read(nil, k2)
								end
								i = i + k
							end
						else --repeat: n = number of pixels to repeat, k = color
							assert(i + n <= width, 'RLE overflow')
							ffi.fill(row_bmp.data + i, n, k)
							i = i + n
						end
					end
				end
			else
				function read_row()
					read(row_bmp.data, row_bmp.stride)
				end
			end

			local dst_x = dst_x or 0
			local dst_y = dst_y or 0
			local function load_row(j)
				read_row()
				bitmap.paint(row_bmp, dst_bmp, dst_x, dst_y + j,
					convert_pixel, src_colorspace, dst_colorspace)
			end

			load_pal()

			if bottom_up then
				for j = height-1, 0, -1 do
					load_row(j)
				end
			else
				for j = 0, height-1 do
					load_row(j)
				end
			end
		end

	end

	--gather everything in a bmp object
	local bmp = {}
	bmp.compression = comp
	bmp.image_offset = fh.image_offset
	bmp.seek_to_image = fh.image_offset - ffi.sizeof(fh) - z
	bmp.bpp = bpp
	bmp.bottom_up = bottom_up
	bmp.w = width
	bmp.h = height

	bmp.palette = {}
	bmp.palette.count = pal_count

	function bmp.palette:load()
		load_pal()
		self.data = pal
	end

	function bmp.palette:entry(i)
		return pal_entry(i)
	end

	bmp.load = load

	return bmp
end

local header_cts = {
	core = core_header,
	info = info_header,
	v2 = v2_header,
	v3 = v3_header,
	v4 = v4_header,
	v5 = v5_header,
}
function M.save(bmp, write, header_format, bottom_up)
	local h_fmt = header_format or 'info'
	local h_ct = assert(header_cts[h_fmt], 'invalid header format')
	bottom_up = bottom_up
	local h = h_ct()
	h.w = bmp.w
	h.h = (bottom_up and 1 or -1) * bmp.h

	write(h, ffi.sizeof(h))
end

return M
