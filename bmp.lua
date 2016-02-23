
--BMP file load/save.
--Written by Cosmin Apreutesei. Public Domain.

local ffi = require'ffi'
local bit = require'bit'
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

local valid_bpps_core = {
	[ 1] = true,
	[ 4] = true,
	[ 8] = true,
	[16] = true,
	[24] = true,
}

local valid_bpps_info = {
	[ 1] = true,
	[ 4] = true,
	[ 8] = true,
	[16] = true,
	[24] = true,
	[ 0] = true, --JPEG, PNG
	[32] = true,
	[64] = true, --GDI+
}

local compressions = {[0] = 'rgb', 'rle8', 'rle4', 'bitfields',
	'jpeg', 'png', 'alphabitfields'}

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
	local h
	local core --the ancient core header is more restricted
	local quad_mask = true --the bitfields mask can be a rgb quad or a triple
	local quad_pal = true --palette entries are quads except for core header
	if z == ffi.sizeof(core_header) then
		core = true
		quad_pal = false
		h = read(core_header())
	elseif z == ffi.sizeof(info_header) then
		quad_mask = false
		h = read(info_header())
	elseif z == ffi.sizeof(v2_header) then
		quad_mask = false
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
	local bpp = h.bpp
	local valid_bpps = core and valid_bpps_core or valid_bpps_info
	assert(valid_bpps[bpp], 'invalid bpp')
	local comp = core and 0 or h.compression
	local comp = assert(compressions[comp], 'invalid compression type')
	if comp == 'rle4' then assert(bpp == 4, 'invalid bpp') end
	if comp == 'rle8' then assert(bpp == 8, 'invalid bpp') end
	local width = h.w
	local height = math.abs(h.h)
	local bottom_up = h.h > 0
	assert(width >= 1, 'invalid width')
	assert(height >= 1, 'invalid height')

	--load the channel masks for BI_BITFIELDS bitmaps
	local mask_r, mask_g, mask_b, mask_a
	if comp == 'bitfields' then
		local mask = read(quad_mask and rgb_quad() or rgb_triple())
		mask_r = mask.r
		mask_g = mask.g
		mask_b = mask.b
		mask_a = quad_mask and mask.a or nil
	end

	--make a palette loader and indexer
	local pal_size = fh.image_offset - bytes_read
	local pal_entry_ct = quad_pal and rgb_quad or rgb_triple
	local pal_ct = ffi.typeof('$[?]', pal_entry_ct)
	local pal_count = 0
	if bpp <= 8 then
		pal_count = math.floor(pal_size / ffi.sizeof(pal_entry_ct))
		pal_count = math.min(pal_count, 2^bpp)
	end
	local pal
	local function load_pal()
		if pal then return end
		if pal_count > 0 then
			pal = read(pal_ct(pal_count))
			read(nil, pal_size - ffi.sizeof(pal)) --null-read to pixel data
		else
			pal = true
			read(nil, pal_size) --null-read to pixel data
		end
	end
	local function pal_entry(i)
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
			local bitmap = require'bitmap'

			--allocate a single-row bitmap in the original format.
			local bitmap_formats = {
				--paletted, using custom pixel converter
				[1] = 'g1',
				[4] = 'g4',
				[8] = 'g8',
				--non-paletted, using built-in converters
				[16] = 'rgb555',
				[24] = 'bgr8',
				[32] = 'bgrx8',
				[64] = 'bgrx16',
			}
			local row_bmp = bitmap.new(width, 1, bitmap_formats[bpp], bottom_up, true)

			--ga8 -> rgba8 pixel converters for paletted bitmaps.
			local convert_pixel
			if bpp <= 8 then
				local shr = bit.rshift
				if bpp == 1 then
					function convert_pixel(g8)
						return pal_entry(shr(g8, 7))
					end
				elseif bpp == 4 then
					function convert_pixel(g8)
						return pal_entry(shr(g8, 4))
					end
				elseif bpp == 8 then
					convert_pixel = pal_entry
				end
			end

			--check bitmap stride against the known stride formula.
			local src_stride = math.floor((bpp * width + 31) / 32) * 4
			assert(row_bmp.stride == src_stride)

			local rle = comp:find'^rle'
			local bitfields = comp:find'bitfields$'

			--row reader: either straight read or RLE decode
			local read_row
			if rle then
				assert(bpp == 8, 'RLE4 not supported')
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
				bitmap.paint(row_bmp, dst_bmp, dst_x, dst_y + j, convert_pixel, 'ga8', 'rgba8')
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
	bmp.mask_r = mask_r
	bmp.mask_g = mask_g
	bmp.mask_b = mask_b
	bmp.mask_a = mask_a
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
		load_pal()
		return pal_entry(i)
	end

	bmp.load = load

	return bmp
end


if not ... then

	local lfs = require'lfs'
	local glue = require'glue'
	local bitmap = require'bitmap'
	local bmp = M

	local function test(f)
		local s = glue.readfile(f)
		assert(#s > 0)
		print('> '..f, #s)
		local function read(buf, size)
			assert(#s >= size, 'file too short')
			if buf then
				local s1 = s:sub(1, size)
				ffi.copy(buf, s1, size)
			end
			s = s:sub(size + 1)
		end
		local bmp = bmp.open(read)
		local dbmp = bitmap.new(bmp.w, bmp.h, 'bgra8')
		bmp:load(dbmp)
	end

	for i,d in ipairs{'good'} do--, 'bad', 'questionable'} do
		for f in lfs.dir('media/bmp/'..d) do
			if f:find'%.bmp$' then
				local ok, err = xpcall(test, debug.traceback, 'media/bmp/'..d..'/'..f)
				if not ok then print(err) end
			end
		end
	end

end


return M
