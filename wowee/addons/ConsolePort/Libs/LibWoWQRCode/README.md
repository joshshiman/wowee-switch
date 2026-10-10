
# LibWoWQRCode

A Lua library for generating and rendering QR codes in World of Warcraft UI frames.

## Main Functions

### `QR(str, size, [parent, drawLayer])`
Generates a QR code from the given string and creates a new frame (canvas) of the given size, rendering the QR code centered with padding. Returns the canvas frame containing the QR code.

- `str`: The string to encode as a QR code.
- `size`: The width/height (pixels) of the QR code frame.
- `parent` (optional): The parent frame to attach the QR code canvas to. If omitted, uses an internal hidden frame.
- `drawLayer` (optional): The draw layer for the textures (default: 'ARTWORK').

### `canvas:Release()`
Releases the canvas and its associated textures back to the pool for reuse.

## Usage Example

```lua
local canvas = QR("https://www.example.com", 128, MyParentFrame)
-- ...
canvas:Release()
```

## Notes
- The library uses frame and texture pools for efficient reuse.
- The QR code canvas is a frame you can position, parent, or hide as needed.

## License
This library includes code from [luaqrcode](https://github.com/speedata/luaqrcode), licensed under the 3-clause BSD license.
