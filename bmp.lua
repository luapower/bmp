
--BMP file load/save.
--Written by Cosmin Apreutesei. Public Domain.

local ffi = require'ffi'
local M = {}

--BITMAPFILEHEADER
local file_header = ffi.typeof[[struct __attribute__((__packed__)) {
	char     magic[2]; // 'BM'
	uint32_t size;
	uint16_t reserved1;
	uint16_t reserved2;
	uint32_t pixels_offset;
	uint32_t header_size;
}]]

--BITMAPCOREHEADER, Windows 2.0 or later
local core_header = ffi.typeof[[struct __attribute__((__packed__)) {
	// BITMAPCOREHEADER
	uint16_t w;
	uint16_t h;
	uint16_t planes;       // 1
	uint16_t bpp;          // 1, 4, 8, 16, 24, 32; 64 (GDI+)
}]]

--BITMAPINFOHEADER, Windows NT, 3.1x or later
local info_header = ffi.typeof[[struct __attribute__((__packed__)) {
	int32_t  w;
	int32_t  h;
	uint16_t planes;       // 1
	uint16_t bpp;          // 1, 4, 8, 16, 24, 32; 64 (GDI+)
	uint32_t compression;  // 0-6, 11-13
	uint32_t pixels_size;  // 0 for BI_RGB
	uint32_t dpi_v;
	uint32_t dpi_h;
	uint32_t palette_colors; // 0 = 2^n
	uint32_t palette_colors_important; // ignored
}
]]

--BITMAPV4HEADER, Windows NT 4.0, 95 or later
local v4_header = ffi.typeof([[struct __attribute__((__packed__)) {
	$;
	uint32_t mask_r;
	uint32_t mask_g;
	uint32_t mask_b;
	uint32_t mask_a;
	uint32_t cs_type;
	struct { int32_t rx, ry, rz, gx, gy, gz, bx, by, bz; } endpoints;
	uint32_t gamma_r;
	uint32_t gamma_g;
	uint32_t gamma_b;
}]], info_header)

--BITMAPV5HEADER, Windows NT 5.0, 98 or later
local v5_header = ffi.typeof([[struct __attribute__((__packed__)) {
	$;
	uint32_t intent;
	uint32_t profile_data;
	uint32_t profile_size;
	uint32_t reserved;
}]], v4_header)

function M.load_header(read)
	local h = file_header()
	read(h, ffi.sizeof(h))
	assert(ffi.string(h.magic, 2) == 'BM')
	local z = h.header_size - 4
	local pixels_offset = h.pixels_offset

	if z == ffi.sizeof(core_header) then
		h = core_header()
		read(h, z)
	elseif z == ffi.sizeof(info_header) then
		h = info_header()
		read(h, z)
		if h.compression == 3 then --BI_BITFIELDS
			--bit field masks
		end
	elseif z == ffi.sizeof(v4_header) then
		h = v4_header()
		read(h, z)
	elseif z == ffi.sizeof(v5_header) then
		h = v5_header()
		read(h, z)
	else
		error('invalid info header size '..(z+4))
	end
	return h, pixels_offset
end

function M.load(read, write)
	local h, pixels_offset = M.load_header(read)
	read(nil, pixels_offset)
	local stride = (h.bpp * h.w + 31) / 32 * 4
	local buf = ffi.new('uint8_t*', stride)
	for i = 0, math.abs(h.h)-1 do
		read(buf, stride)
		write(buf, stride)
	end
end

function M.as_bitmap(read)
	local h, pixels_offset = M.load_header(read)
	read(nil, pixels_offset)
	local stride = (h.bpp * h.w + 31) / 32 * 4
	local size = stride * math.abs(h.h)
	local data = ffi.new('uint8_t[?]', size)
	--read(data, size)
	return {
		data = data,
		size = size,
		format = h.bpp,
		stride = stride,
		w = h.w,
		h = math.abs(h.h),
		bottom_up = h.h > 0,
	}
end

--[=[


--parse a 16-bit WORD from the binary string
local function word(s, offset)
	local lo = s:byte(offset)
	local hi = s:byte(offset + 1)
	return hi*256 + lo
end

--parse a 32-bit DWORD from the binary string
local function dword(s, offset)
	local lo = word(s, offset)
	local hi = word(s, offset + 2)
	return hi*65536 + lo
end

local function parse_header(block) --34 bytes needed
	-- BITMAPFILEHEADER (14 bytes long)
	assert(word(header, 1) == 0x4D42, 'not a BMP file')
	local bits_offset = word(header, offset + 10)
	-- BITMAPINFOHEADER
	offset = 15 -- start from the 15-th byte
	local width       = dword(header, offset + 4)
	local height      = dword(header, offset + 8)
	local bpp         =  word(header, offset + 14) --1, 2, 4, 8, 16, 24, 32
	local compression = dword(header, offset + 16) --0 = none, 1 = RLE-8, 2 = RLE-4, 3 = Huffman, 4 = JPEG/RLE-24, 5 = PNG
end

-- Parse the bits of an open BMP file
parse = function(file, bits, chunk, r, g, b)
	r = r or {}
	g = g or {}
	b = b or {}
	local bpp = bits/8
	local bytes = file:read(chunk*bpp) -- todo: "*a"
	if bytes == nil then
		-- end of file
		file:close()
		return
	end
	for i = 0, chunk - 1 do
		local o = i*bpp
		insert(r, byte(bytes, o + 3))
		insert(g, byte(bytes, o + 2))
		insert(b, byte(bytes, o + 1))
	end
	return r, g, b
end
]=]



if not ... then

	local lfs = require'lfs'
	local glue = require'glue'
	local bmp = M

	local function test(f)
		local s = glue.readfile(f)
		print(f)
		local b = bmp.as_bitmap(function(buf, size)
			local s1 = s:sub(1, size)
			if s1 == '' then return end
			s = s:sub(size+1)
			if buf then
				ffi.copy(buf, s1)
			end
			return #s1
		end)
		print(b.format, b.w, b.h, b.bottom_up)
	end

	for i,d in ipairs{'good', 'bad', 'questionable'} do
		for f in lfs.dir('media/bmp/'..d) do
			if f:find'%.bmp$' then
				test('media/bmp/'..d..'/'..f)
			end
		end
	end

end


return M
