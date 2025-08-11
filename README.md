# Sarek PDF Viewer

A Zathura-like PDF viewer implemented in Zig with vim-style key bindings.

## Features

- **Vim-style navigation**: Use `j/k` for next/previous page, `h/l` for left/right navigation
- **Zoom controls**: `+/-` for zoom in/out, `0` for original size, `a` for fit page, `s` for fit width
- **Backend architecture**: Pluggable backend system with Poppler as the default
- **Cairo rendering**: High-quality PDF rendering using Cairo graphics
- **GTK3 interface**: Native GTK3 window management

## Key Bindings

| Key | Action |
|-----|--------|
| `j`, `Space`, `Enter` | Next page |
| `k`, `Backspace` | Previous page |
| `g` | Go to first page |
| `G` | Go to last page |
| `h`, `←` | Scroll left |
| `l`, `→` | Scroll right |
| `↑` | Scroll up |
| `↓` | Scroll down |
| `+`, `=` | Zoom in |
| `-` | Zoom out |
| `0` | Original size |
| `a` | Fit page |
| `s` | Fit width |
| `q`, `Esc` | Quit |
| `r` | Refresh |
| `F` | Toggle fullscreen |
| `/` | Search forward |
| `?` | Search backward |
| `n` | Next search result |
| `N` | Previous search result |

## Architecture

```
src/
├── main.zig              # Entry point
├── viewer.zig            # Main viewer logic
├── backends/
│   ├── backend.zig       # Backend interface
│   └── poppler.zig       # Poppler backend implementation
├── input/
│   ├── commands.zig      # Command definitions
│   └── keybindings.zig   # Key binding system
└── config/
    └── config.zig        # Configuration management
```

## Dependencies

- Zig 0.14+
- GTK3 development libraries
- Poppler development libraries
- Cairo development libraries


### Arch Linux
```bash
sudo pacman -S gtk3 poppler-glib cairo
```

### Ubuntu/Debian
```bash
sudo apt-get install libgtk-3-dev libpoppler-glib-dev libcairo2-dev
```

## Building

```bash
zig build
```

## Running

```bash
zig build run -- path/to/document.pdf
```

Or after building:

```bash
./zig-out/bin/sarek path/to/document.pdf
```

## Documentation
- Glib: https://docs.gtk.org/glib/
- Poppler: https://poppler.freedesktop.org/api/glib/
- Gtk3: https://docs.gtk.org/gtk3/
- Cairo: https://www.cairographics.org/documentation/

## TODO
- Performance issues with PDF with many pages. (TOC navigation as well as page navigation)
- Fix fit to page/width.
- Fix issues of last page when fit to page/width mode.


## Explore
- Find order of points to make a quadrilateral