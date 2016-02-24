---
tagline: BMP file encoding and decoding
---

## `local bmp = require'bmp'`

## API

--------------------------------------- ---------------------------------------
`bmp.open(read) -> b`                   open a BMP file and read it's header
`b:load(dst_bmp[, x, y])`               load a BMP file into a [bitmap]
`b.palette:load()`                      load the palette
`b.palette:entry(index) -> r, g, b, a`  palette lookup
`b.palette.count`                       palette count
`bmp.save(bmp, write)`                  save a bitmap
--------------------------------------- ---------------------------------------

