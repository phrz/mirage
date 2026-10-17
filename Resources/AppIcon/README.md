# App icon

- `Mirage.icon` — Icon Composer source (macOS 26+ layered icon; Default and Dark final, Mono still being tuned).
- `Mirage-1024.png` — flat composite, squircle-masked.
- `Mirage.icns` — fallback for pre-Tahoe and for the ad-hoc viewer bundle (`scripts/make-viewer-app.sh`).

## Source

Everything above is generated from `Source/`:

- `Source/Mirage Icon.sketch` — editable Sketch document (pages: Icon, Variants, Icon Composer Layers).
- `Source/gen_textures.py` — procedural sand plane (grain, speckle relief, wind ripples, haze, inferior-mirage band).
- `Source/mirage-icon.sketchplugin` — Sketch plugin that builds the document (`build2`) and exports the Icon Composer layers (`export`).
- `Source/make_icon.py` — assembles `Mirage.icon`, `Mirage-1024.png` and `Mirage.icns` from the exported layers.

Rebuild from `Source/` with Sketch running:

```bash
uv run --with numpy --with pillow python -I gen_textures.py 620
ST=/Applications/Sketch.app/Contents/Resources/sketchtool/bin/sketchtool
"$ST" run "$PWD/mirage-icon.sketchplugin" build2 --without-activating=YES
"$ST" run "$PWD/mirage-icon.sketchplugin" export --without-activating=YES
uv run --with numpy --with pillow python -I make_icon.py
```
