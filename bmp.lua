
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
	uint16_t bpp;          // 0, 1, 4, 8, 16, 24, 32; 64 (GDI+)
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

local valid_bpps = {
	[0] = true,
	[1] = true,
	[4] = true,
	[8] = true,
	[16] = true,
	[24] = true,
	[32] = true,
	[64] = true,
}

function M.load_header(read)
	local h = file_header()
	read(h, ffi.sizeof(h))
	assert(ffi.string(h.magic, 2) == 'BM')
	local z = h.header_size - 4
	local pixels_offset = h.pixels_offset
	local compression
	if z == ffi.sizeof(core_header) then
		h = core_header()
		read(h, z)
	elseif z == ffi.sizeof(info_header) then
		h = info_header()
		read(h, z)
		compression = h.compression
		if h.compression == 3 then --BI_BITFIELDS
			--bit field masks
		end
	elseif z == ffi.sizeof(v4_header) then
		h = v4_header()
		compression = h.compression
		read(h, z)
	elseif z == ffi.sizeof(v5_header) then
		h = v5_header()
		compression = h.compression
		read(h, z)
	elseif z == 64 + 4 then
		error'OS22XBITMAPHEADER NYI'
	elseif z == 52 + 4 then
		error'BITMAPV2INFOHEADER NYI'
	elseif z == 56 + 4 then
		error'BITMAPV3INFOHEADER NYI'
	else
		error('invalid info header size '..(z+4))
	end
	assert(h.planes == 1, 'invalid number of planes')
	assert(valid_bpps[h.bpp], 'invalid bpp')
	assert(h.w >= 1, 'invalid width')
	assert(math.abs(h.h) >= 1, 'invalid height')
	local bmp = {}
	bmp.compression = compression
	bmp.pixels_offset = pixels_offset
	bmp.seek_to_pixels = pixels_offset - ffi.sizeof(file_header) - z
	bmp.bpp = h.bpp
	bmp.bottom_up = h.h >= 0
	bmp.w = h.w
	bmp.h = math.abs(h.h)
	bmp.stride = math.floor((h.bpp * h.w + 31) / 32) * 4
	return bmp
end

function M.decoder(bmp)
	local c = bmp.compression
	local bpp = bmp.bpp
	if not c or c == 0 then --BI_RGB
		local dstride = nil --means: use sbuf
		return dstride, function(sbuf, dbuf) end --noop
	elseif c == 1 then --BI_RLE8
		assert(bpp == 8, 'invalid bpp')
		error'RLE8 NYI'
		local dstride = h.w * 4
		return dstride, function(sbuf, dbuf)
		end
	elseif c == 2 then --BI_RLE4
		error'RLE4 NYI'
		assert(bpp == 4, 'invalid bpp')
		local dstride = h.w * 4
		return dstride, function(sbuf, dbuf)
		end
	elseif c == 3 then --BI_BITFIELDS
		local dstride = nil
		error'BITFIELDS NYI'
		return dstride, function(buf, sz)
		end
	elseif c == 4 then --BI_JPEG
		error'jpeg NYI'
	elseif c == 5 then --BI_PNG
		error'png NYI'
	elseif c == 6 then --BI_ALPHABITFIELDS: Windows CE 5.0 with .NET 4.0 or later
		local dstride = nil
		return dstride, function(buf, sz)
		end
	else
		error('invalid compression method '..c)
	end
end

function M.alloc(size)
	return ffi.new('uint8_t[?]', size)
end

function M.load(bmp, read, write, alloc)
	alloc = alloc or M.alloc
	read(nil, bmp.seek_to_pixels)
	local dstride, decode = M.decoder(bmp)
	local sbuf = alloc(bmp.stride)
	local dbuf = dstride and alloc(dstride) or sbuf
	for i = 0, bmp.h-1 do
		read(sbuf, bmp.stride)
		decode(sbuf, dbuf)
		write(dbuf, dstride)
	end
end

function M.as_bitmap(read, alloc)
	alloc = alloc or M.alloc
	local bmp = M.load_header(read)
	local dstride = M.decoder(bmp)
	local stride = dstride or bmp.stride
	local size = stride * bmp.h
	local data = alloc(stride)
	local format = nil --format
	local function write(dbuf, dstride)
		--
	end
	M.load(bmp, read, write, alloc)
	return {
		data = data,
		size = size,
		format = format,
		stride = stride,
		w = bmp.w,
		h = bmp.h,
		bottom_up = bmp.bottom_up,
	}
end


if not ... then

	local lfs = require'lfs'
	local glue = require'glue'
	local bmp = M

	local function test(f)
		local s = glue.readfile(f)
		assert(#s > 0)
		print('> '..f, #s)
		local function read(buf, size)
			assert(#s >= size, 'file too short')
			local s1 = s:sub(1, size)
			s = s:sub(size + 1)
			if buf then
				ffi.copy(buf, s1, size)
			end
			return #s1
		end
		local b = bmp.as_bitmap(read, glue.malloc)
		--print('conclusion', b.format, b.w, b.h, b.bottom_up)
	end

	for i,d in ipairs{'good', 'bad', 'questionable'} do
		for f in lfs.dir('media/bmp/'..d) do
			if f:find'%.bmp$' then
				local ok, err = pcall(test, 'media/bmp/'..d..'/'..f)
				if not ok then print(err) end
			end
		end
	end

end


return M
