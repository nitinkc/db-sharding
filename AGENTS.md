# Project verification

- Manage the documentation environment with uv: `uv sync --locked`.
- Validate documentation changes with `uv run mkdocs build --strict`.
- Preview locally with `uv run mkdocs serve`.
- All course content lives under `docs/`: `index.md`, `modules/`, `labs/`, `solutions/`, and `diagrams/`. MkDocs reads these directly; no content-copying hook is needed. Keep the root README as a repository quick start.
- Generated output is written to `site/` and must not be committed.
- Pages embed SVG exports alongside editable `.drawio` sources in `docs/diagrams/`. After editing diagrams, regenerate exports locally with `"/Applications/Development/draw.io.app/Contents/MacOS/draw.io" --export --format svg --theme light --embed-svg-fonts false --border 16 docs/diagrams`.
